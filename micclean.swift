// micclean.swift — microfone virtual com redução de eco e ruído para macOS
//
// Caminho do som:
//   microfone → processamento de voz da Apple (Isolamento de Voz) → redução de reverberação
//             → noise gate → ganho/limitador → EQ → BlackHole 2ch
// Nos apps (Meet, Slack, WhatsApp...), use "BlackHole 2ch" (ou "Padrão do sistema").
//
// Compilar:  swiftc -O -target "$(uname -m)-apple-macos13" micclean.swift -o micclean
// Ajuda:     ./micclean --help
// Instalação como serviço: veja install.sh e README.md
//
// Licença: MIT

import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import os
import Accelerate

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Utilidades

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("ERRO: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

func check(_ st: OSStatus, _ what: String) throws {
    if st != noErr {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(st),
                      userInfo: [NSLocalizedDescriptionKey: "\(what) (erro \(st))"])
    }
}

func usage() -> String {
    """
    Uso: micclean [opções]
      --source NOME       microfone de origem (padrão: ME6S)
      --sink NOME         saída virtual (padrão: BlackHole 2ch)
      --no-dereverb       desliga a redução de reverberação
      --rt60 S            tempo de reverberação estimado da sala, em s (padrão: 1.5)
      --strength X        intensidade da redução de reverberação (padrão: 2.0; teste 0.5 a 3.0)
      --floor DB          atenuação máxima da reverberação por frequência (padrão: -25)
      --no-vp             não usa o processamento de voz da Apple (Isolamento de Voz)
      --no-eq             desliga a equalização
      --gain DB           ganho de saída (padrão: 6; um limitador evita distorção)
      --presence DB       reforço de clareza em 3,5 kHz (padrão: 6)
      --no-gate           desliga o noise gate
      --gate DB           limiar do gate em dBFS (padrão: -45)
      --gate-range DB     atenuação com o gate fechado (padrão: -45)
      --gate-hold MS      tempo que o gate segura aberto após a fala (padrão: 150)
      --gate-release MS   velocidade de fechamento do gate (padrão: 60)
      --meter             mostra o nível de entrada a cada segundo
      --list              lista os dispositivos de áudio e sai
    """
}

// MARK: - CoreAudio: dispositivos

func addr(_ sel: AudioObjectPropertySelector,
          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func allDevices() -> [AudioDeviceID] {
    var a = addr(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    let sys = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func deviceName(_ id: AudioDeviceID) -> String {
    var a = addr(kAudioObjectPropertyName)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let st = withUnsafeMutablePointer(to: &name) {
        AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0)
    }
    guard st == noErr, let n = name else { return "?" }
    return n.takeRetainedValue() as String
}

func channelCount(_ id: AudioDeviceID, input: Bool) -> Int {
    var a = addr(kAudioDevicePropertyStreamConfiguration,
                 input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                               alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func findDevice(_ name: String, input: Bool) -> AudioDeviceID? {
    allDevices().first {
        deviceName($0).caseInsensitiveCompare(name) == .orderedSame && channelCount($0, input: input) > 0
    }
}

func listDevices() {
    print("Dispositivos de áudio:")
    for id in allDevices() {
        print("  \(deviceName(id))  entrada: \(channelCount(id, input: true))  saída: \(channelCount(id, input: false))")
    }
}

// MARK: - Captura direta do microfone (AUHAL)

func defaultOutputDevice() -> AudioDeviceID {
    var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
    return id
}

/// Captura o microfone. Com `voiceProcessing`, usa o processamento de voz da Apple
/// (VoiceProcessingIO), que habilita o "Isolamento de Voz" na Central de Controle.
final class HALCapture {
    private var unit: AudioUnit?
    let sampleRate: Double
    let voiceProcessing: Bool
    private let maxFrames: UInt32 = 8192
    private let buffer: UnsafeMutablePointer<Float>
    private var abl = AudioBufferList()
    var handler: ((UnsafeMutablePointer<Float>, Int) -> Void)?

    init(device: AudioDeviceID, voiceProcessing vp: Bool, outputDevice: AudioDeviceID) throws {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: vp ? kAudioUnitSubType_VoiceProcessingIO
                                                                  : kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw NSError(domain: "micclean", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "componente de áudio não encontrado"])
        }
        var u: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &u), "criar unidade de captura")
        guard let au = u else {
            throw NSError(domain: "micclean", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "unidade de captura nula"])
        }
        var ok = false
        defer { if !ok { AudioComponentInstanceDispose(au) } }

        var one: UInt32 = 1, zero: UInt32 = 0
        let u32 = UInt32(MemoryLayout<UInt32>.size)
        let devSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var rate: Double

        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, u32),
                  "habilitar entrada")

        if vp {
            // VoiceProcessingIO: entrada = microfone, saída = alto-falante (fica em silêncio)
            var inDev = device, outDev = outputDevice
            try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 1,
                                           &inDev, devSize), "selecionar o microfone (voz)")
            try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                           &outDev, devSize), "selecionar a saída (voz)")
            rate = 48000
            var mono = AudioStreamBasicDescription(
                mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
            try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                           &mono, fmtSize), "definir o formato de captura (voz)")
            try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                           &mono, fmtSize), "definir o formato de saída (voz)")
            // A saída do processamento de voz só toca silêncio
            var silent = AURenderCallbackStruct(
                inputProc: { _, flags, _, _, _, ioData in
                    if let io = ioData {
                        for b in UnsafeMutableAudioBufferListPointer(io) {
                            if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) }
                        }
                    }
                    flags.pointee.insert(.unitRenderAction_OutputIsSilence)
                    return noErr
                },
                inputProcRefCon: nil)
            try check(AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                           &silent, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                      "registrar saída silenciosa")
            if #available(macOS 14.0, *) {
                // Não abaixar o volume dos outros apps (ex.: o áudio da chamada)
                var duck = AUVoiceIOOtherAudioDuckingConfiguration(mEnableAdvancedDucking: false, mDuckingLevel: .min)
                _ = AudioUnitSetProperty(au, kAUVoiceIOProperty_OtherAudioDuckingConfiguration, kAudioUnitScope_Global,
                                         0, &duck, UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size))
            }
        } else {
            try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, u32),
                      "desabilitar saída")
            var dev = device
            try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                           &dev, devSize), "selecionar o microfone")
            var devFmt = AudioStreamBasicDescription()
            var size = fmtSize
            try check(AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &devFmt, &size),
                      "ler o formato do microfone")
            guard devFmt.mSampleRate > 0 else {
                throw NSError(domain: "micclean", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "taxa de amostragem inválida"])
            }
            rate = devFmt.mSampleRate
            var client = AudioStreamBasicDescription(
                mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
            try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                           &client, fmtSize), "definir o formato de captura")
        }

        unit = au
        sampleRate = rate
        voiceProcessing = vp
        buffer = .allocate(capacity: Int(maxFrames))
        buffer.initialize(repeating: 0, count: Int(maxFrames))

        var cb = AURenderCallbackStruct(
            inputProc: { refCon, flags, ts, bus, frames, _ in
                Unmanaged<HALCapture>.fromOpaque(refCon).takeUnretainedValue().render(flags, ts, bus, frames)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                       &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                  "registrar callback")
        try check(AudioUnitInitialize(au), "inicializar captura")
        ok = true
    }

    fileprivate func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            _ ts: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        guard let au = unit else { return noErr }
        let n = min(frames, maxFrames)
        abl.mNumberBuffers = 1
        abl.mBuffers.mNumberChannels = 1
        abl.mBuffers.mDataByteSize = n * 4
        abl.mBuffers.mData = UnsafeMutableRawPointer(buffer)
        let st = AudioUnitRender(au, flags, ts, 1, n, &abl)
        if st == noErr { handler?(buffer, Int(n)) }
        return st
    }

    func start() throws { if let au = unit { try check(AudioOutputUnitStart(au), "iniciar captura") } }
    func stop() { if let au = unit { AudioOutputUnitStop(au) } }
}

// MARK: - Buffer circular (captura → saída)

final class Ring {
    private let buf: UnsafeMutablePointer<Float>
    private let cap: Int
    private var r = 0, w = 0, n = 0
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    init(capacity: Int) {
        cap = capacity
        buf = .allocate(capacity: capacity)
        buf.initialize(repeating: 0, count: capacity)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    func write(_ p: UnsafePointer<Float>, _ count: Int) {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        for i in 0..<count {
            buf[w] = p[i]
            w = (w + 1) % cap
            if n < cap { n += 1 } else { r = (r + 1) % cap }
        }
    }

    /// Lê `count` amostras (completa com silêncio se faltar). Descarta o excesso
    /// acumulado acima de `maxFill` para a latência não crescer.
    func read(_ p: UnsafeMutablePointer<Float>, _ count: Int, maxFill: Int) {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        if n > maxFill + count {
            let drop = n - maxFill - count
            r = (r + drop) % cap
            n -= drop
        }
        let k = min(count, n)
        for i in 0..<k { p[i] = buf[r]; r = (r + 1) % cap }
        n -= k
        if k < count { for i in k..<count { p[i] = 0 } }
    }
}

// MARK: - Noise gate (corta o "rabo" do eco nas pausas)

final class Gate {
    let enabled: Bool
    private let threshold: Float, floorGain: Float
    private let envAtt: Float, envRel: Float, openC: Float, closeC: Float
    private let holdSamples: Int
    private var env: Float = 0, gain: Float = 1, hold = 0
    var isOpen: Bool { gain > 0.5 }

    init(enabled: Bool, thresholdDB: Float, rangeDB: Float, holdMs: Float, releaseMs: Float, sampleRate: Float) {
        self.enabled = enabled
        threshold = powf(10, thresholdDB / 20)
        floorGain = powf(10, rangeDB / 20)
        envAtt = expf(-1 / (0.001 * sampleRate))
        envRel = expf(-1 / (0.030 * sampleRate))
        openC = expf(-1 / (0.003 * sampleRate))
        closeC = expf(-1 / (max(releaseMs, 5) / 1000 * sampleRate))
        holdSamples = Int(max(holdMs, 0) / 1000 * sampleRate)
    }

    func process(_ p: UnsafeMutablePointer<Float>, _ count: Int) {
        guard enabled else { return }
        for i in 0..<count {
            let a = abs(p[i])
            env = a > env ? a + (env - a) * envAtt : a + (env - a) * envRel
            if env > threshold { hold = holdSamples } else if hold > 0 { hold -= 1 }
            let target: Float = hold > 0 ? 1 : floorGain
            gain = target + (gain - target) * (target > gain ? openC : closeC)
            p[i] *= gain
        }
    }
}

// MARK: - Redução de reverberação (subtração espectral da reverberação tardia, Lebart et al.)
//
// Para cada frequência, estima a energia da "cauda" da sala a partir do que foi ouvido
// ~50 ms antes (decaindo conforme o RT60) e atenua essa parte do sinal atual.

final class Dereverb {
    static let N = 1024          // tamanho da FFT (~21 ms a 48 kHz)
    static let hop = 256         // sobreposição de 75%
    static let log2n: vDSP_Length = 10

    let enabled: Bool
    private let bins = Dereverb.N / 2 + 1
    private let setup: FFTSetup
    private let win: UnsafeMutablePointer<Float>
    private let inBuf: UnsafeMutablePointer<Float>
    private let outBuf: UnsafeMutablePointer<Float>
    private let frame: UnsafeMutablePointer<Float>
    private let re: UnsafeMutablePointer<Float>
    private let im: UnsafeMutablePointer<Float>
    private let smooth: UnsafeMutablePointer<Float>
    private let hist: UnsafeMutablePointer<Float>
    private let gains: UnsafeMutablePointer<Float>
    private let delayFrames: Int
    private let lateFactor: Float
    private let beta: Float
    private let gMin: Float                  // atenuação máxima por frequência
    private let alphaS: Float = 0.7          // suavização da energia estimada
    private let gainUp: Float = 0.5          // ganho volta rápido quando a voz chega
    private let gainDown: Float = 0.85       // e cai devagar (evita o som metálico)
    private let raw: UnsafeMutablePointer<Float>
    private let olaScale: Float
    private var histPos = 0
    private var pos = 0

    init(enabled: Bool, sampleRate: Double, rt60: Float, strength: Float, floorDB: Float) {
        let n = Dereverb.N, hop = Dereverb.hop, bins = n / 2 + 1
        self.enabled = enabled
        gMin = powf(10, min(floorDB, 0) / 20)
        beta = max(strength, 0)
        let d = max(1, Int((0.05 * sampleRate / Double(hop)).rounded()))
        delayFrames = d
        let td = Float(d * hop) / Float(sampleRate)
        let decay = 3 * logf(10) / max(rt60, 0.1)
        lateFactor = expf(-2 * decay * td)
        olaScale = 1 / (2 * Float(n)) / 1.5     // escala da FFT real + soma das janelas Hann²

        guard let s = vDSP_create_fftsetup(Dereverb.log2n, FFTRadix(kFFTRadix2)) else {
            fail("não foi possível criar a FFT.")
        }
        setup = s

        func alloc(_ c: Int, _ v: Float = 0) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: c)
            p.initialize(repeating: v, count: c)
            return p
        }
        win = alloc(n)
        for i in 0..<n { win[i] = 0.5 - 0.5 * cosf(2 * Float.pi * Float(i) / Float(n)) }
        inBuf = alloc(n); outBuf = alloc(n); frame = alloc(n)
        re = alloc(n / 2); im = alloc(n / 2)
        smooth = alloc(bins); hist = alloc(bins * d); gains = alloc(bins, 1); raw = alloc(bins, 1)
    }

    func process(_ p: UnsafeMutablePointer<Float>, _ count: Int) {
        guard enabled else { return }
        let n = Dereverb.N, hop = Dereverb.hop
        for i in 0..<count {
            inBuf[n - hop + pos] = p[i]
            p[i] = outBuf[pos]
            pos += 1
            if pos == hop { pos = 0; processFrame() }
        }
    }

    private func processFrame() {
        let n = Dereverb.N, hop = Dereverb.hop, half = n / 2
        vDSP_vmul(inBuf, 1, win, 1, frame, 1, vDSP_Length(n))

        var split = DSPSplitComplex(realp: re, imagp: im)
        frame.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(setup, &split, 1, Dereverb.log2n, FFTDirection(FFT_FORWARD))

        let row = hist + histPos * bins          // energia de ~50 ms atrás

        // 1) ganho bruto por frequência
        for k in 0..<bins {
            let xr: Float, xi: Float
            if k == 0 { xr = re[0]; xi = 0 }
            else if k == half { xr = im[0]; xi = 0 }
            else { xr = re[k]; xi = im[k] }
            let pw = xr * xr + xi * xi + 1e-12
            var g = 1 - beta * lateFactor * row[k] / pw
            if g < gMin { g = gMin } else if g > 1 { g = 1 }
            raw[k] = g
            smooth[k] = alphaS * smooth[k] + (1 - alphaS) * pw
            row[k] = smooth[k]
        }

        // 2) suaviza entre frequências vizinhas (±3 bins) e no tempo
        for k in 0..<bins {
            let lo = max(0, k - 3), hi = min(bins - 1, k + 3)
            var s: Float = 0
            for j in lo...hi { s += raw[j] }
            let g = s / Float(hi - lo + 1)
            let a = g > gains[k] ? gainUp : gainDown
            gains[k] = a * gains[k] + (1 - a) * g
        }

        // 3) aplica
        re[0] *= gains[0]
        im[0] *= gains[half]
        for k in 1..<half { re[k] *= gains[k]; im[k] *= gains[k] }
        histPos = (histPos + 1) % delayFrames

        vDSP_fft_zrip(setup, &split, 1, Dereverb.log2n, FFTDirection(FFT_INVERSE))
        frame.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
        }
        vDSP_vmul(frame, 1, win, 1, frame, 1, vDSP_Length(n))
        var sc = olaScale
        vDSP_vsmul(frame, 1, &sc, frame, 1, vDSP_Length(n))

        // overlap-add
        memmove(outBuf, outBuf + hop, (n - hop) * MemoryLayout<Float>.size)
        memset(outBuf + (n - hop), 0, hop * MemoryLayout<Float>.size)
        vDSP_vadd(outBuf, 1, frame, 1, outBuf, 1, vDSP_Length(n))
        memmove(inBuf, inBuf + hop, (n - hop) * MemoryLayout<Float>.size)
    }
}

// MARK: - Ganho + limitador (aumenta o volume sem distorcer)

final class Limiter {
    private let gain: Float
    private let ceiling: Float = 0.5          // -6 dBFS: deixa folga para o reforço da EQ
    private let release: Float
    private var env: Float = 1

    init(gainDB: Float, sampleRate: Float) {
        gain = powf(10, max(-24, min(gainDB, 24)) / 20)
        release = expf(-1 / (0.15 * sampleRate))
    }

    func process(_ p: UnsafeMutablePointer<Float>, _ count: Int) {
        for i in 0..<count {
            let x = p[i] * gain
            let a = abs(x)
            let needed: Float = a > ceiling ? ceiling / a : 1
            env = needed < env ? needed : needed + (env - needed) * release
            p[i] = x * env
        }
    }
}

// MARK: - Medidor de nível

final class Meter {
    var peakDB: Float = -120
    var frames = 0
}

// MARK: - Configuração

struct Config {
    var source = "ME6S"
    var sink = "BlackHole 2ch"
    var eq = true
    var voiceProcessing = true
    var gainDB: Float = 6
    var presenceDB: Float = 6
    var dereverb = true
    var rt60: Float = 1.5
    var strength: Float = 2.0
    var floorDB: Float = -25
    var gate = true
    var gateDB: Float = -45
    var gateRangeDB: Float = -45
    var gateHoldMs: Float = 150
    var gateReleaseMs: Float = 60
    var meter = false
}

func parseArgs() -> Config {
    var c = Config()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--source": c.source = it.next() ?? c.source
        case "--sink": c.sink = it.next() ?? c.sink
        case "--no-eq": c.eq = false
        case "--gain": c.gainDB = Float(it.next() ?? "") ?? c.gainDB
        case "--presence": c.presenceDB = Float(it.next() ?? "") ?? c.presenceDB
        case "--no-dereverb": c.dereverb = false
        case "--rt60": c.rt60 = Float(it.next() ?? "") ?? c.rt60
        case "--strength": c.strength = Float(it.next() ?? "") ?? c.strength
        case "--floor": c.floorDB = Float(it.next() ?? "") ?? c.floorDB
        case "--gate-hold": c.gateHoldMs = Float(it.next() ?? "") ?? c.gateHoldMs
        case "--gate-release": c.gateReleaseMs = Float(it.next() ?? "") ?? c.gateReleaseMs
        case "--no-gate": c.gate = false
        case "--gate": c.gateDB = Float(it.next() ?? "") ?? c.gateDB
        case "--gate-range": c.gateRangeDB = Float(it.next() ?? "") ?? c.gateRangeDB
        case "--meter": c.meter = true
        case "--no-vp": c.voiceProcessing = false
        case "--list": listDevices(); exit(0)
        case "-h", "--help": print(usage()); exit(0)
        default: fail("opção desconhecida: \(a)\n\(usage())")
        }
    }
    return c
}

// MARK: - Programa principal

let cfg = parseArgs()

guard let srcID = findDevice(cfg.source, input: true) else {
    listDevices(); fail("microfone '\(cfg.source)' não encontrado.")
}
guard let sinkID = findDevice(cfg.sink, input: false) else {
    listDevices(); fail("saída '\(cfg.sink)' não encontrada. O BlackHole está instalado?")
}

// Permissão de microfone
let permSem = DispatchSemaphore(value: 0)
var granted = false
AVCaptureDevice.requestAccess(for: .audio) { ok in granted = ok; permSem.signal() }
permSem.wait()
if !granted {
    fail("sem permissão de microfone. Libere o Terminal em Ajustes → Privacidade e Segurança → Microfone.")
}

// ---- Captura ----
var chosen: HALCapture?
if cfg.voiceProcessing {
    do { chosen = try HALCapture(device: srcID, voiceProcessing: true, outputDevice: defaultOutputDevice()) }
    catch { print("Processamento de voz da Apple indisponível (\(error.localizedDescription)); seguindo sem ele.") }
}
if chosen == nil {
    do { chosen = try HALCapture(device: srcID, voiceProcessing: false, outputDevice: 0) }
    catch { fail("falha ao preparar a captura do '\(cfg.source)': \(error.localizedDescription)") }
}
let capture = chosen!

let SR = capture.sampleRate
let monoFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SR, channels: 1, interleaved: false)!
let ring = Ring(capacity: Int(SR))
let gate = Gate(enabled: cfg.gate, thresholdDB: cfg.gateDB, rangeDB: cfg.gateRangeDB,
                holdMs: cfg.gateHoldMs, releaseMs: cfg.gateReleaseMs, sampleRate: Float(SR))
let limiter = Limiter(gainDB: cfg.gainDB, sampleRate: Float(SR))
let dereverb = Dereverb(enabled: cfg.dereverb, sampleRate: SR, rt60: cfg.rt60, strength: cfg.strength,
                        floorDB: cfg.floorDB)
let meter = Meter()
let maxFill = Int(SR * 0.04)   // até ~40 ms de folga entre captura e saída

capture.handler = { p, n in
    ring.write(p, n)
    var sum: Float = 0
    for i in 0..<n { sum += p[i] * p[i] }
    let db = 10 * log10f(sum / Float(max(n, 1)) + 1e-12)
    if db > meter.peakDB { meter.peakDB = db }
    meter.frames += n
}

// ---- Saída (gate + EQ → BlackHole) ----
let playEngine = AVAudioEngine()
guard let outAU = playEngine.outputNode.audioUnit else { fail("unidade de saída indisponível.") }
var sinkDev = sinkID
let outSt = AudioUnitSetProperty(outAU, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &sinkDev, UInt32(MemoryLayout<AudioDeviceID>.size))
if outSt != noErr { fail("não foi possível direcionar a saída para '\(cfg.sink)' (erro \(outSt)).") }

let srcNode = AVAudioSourceNode(format: monoFmt) { _, _, frameCount, abl -> OSStatus in
    let list = UnsafeMutableAudioBufferListPointer(abl)
    guard let data = list[0].mData else { return noErr }
    let p = data.assumingMemoryBound(to: Float.self)
    let n = Int(frameCount)
    ring.read(p, n, maxFill: maxFill)
    dereverb.process(p, n)
    gate.process(p, n)
    limiter.process(p, n)
    return noErr
}
playEngine.attach(srcNode)

let eq = AVAudioUnitEQ(numberOfBands: 3)
let bands = eq.bands
bands[0].filterType = .highPass;   bands[0].frequency = 90                                    // corta ronco grave
bands[1].filterType = .parametric; bands[1].frequency = 250;  bands[1].bandwidth = 1.0
bands[1].gain = -5                                                                            // tira o "embolado"
bands[2].filterType = .parametric; bands[2].frequency = 3500; bands[2].bandwidth = 1.5
bands[2].gain = cfg.presenceDB                                                                // clareza
for band in bands { band.bypass = !cfg.eq }
playEngine.attach(eq)
playEngine.connect(srcNode, to: eq, format: monoFmt)
playEngine.connect(eq, to: playEngine.mainMixerNode, format: monoFmt)

do { try playEngine.start() }
catch { fail("falha ao iniciar a saída para '\(cfg.sink)': \(error)") }

do { try capture.start() }
catch { fail("falha ao iniciar a captura: \(error.localizedDescription)") }

print("""
micclean rodando
  origem:  \(cfg.source) (\(Int(SR)) Hz)
  processamento de voz Apple: \(capture.voiceProcessing ? "ligado" : "desligado")
  saída:   \(cfg.sink)   ← escolha este como microfone nos apps
  redução de reverberação: \(cfg.dereverb ? String(format: "RT60 %.1f s, intensidade %.1f, limite %.0f dB", cfg.rt60, cfg.strength, cfg.floorDB) : "desligada")
  gate: \(cfg.gate ? String(format: "%.0f dBFS, fechado %.0f dB", cfg.gateDB, cfg.gateRangeDB) : "desligado")   EQ: \(cfg.eq ? String(format: "ligado, clareza +%.0f dB", cfg.presenceDB) : "desligado")   ganho: \(String(format: "%+.0f dB", cfg.gainDB))
Ctrl+C para encerrar.
""")

if capture.voiceProcessing {
    let mode: String
    switch AVCaptureDevice.activeMicrophoneMode {
    case .voiceIsolation: mode = "Isolamento de Voz"
    case .wideSpectrum: mode = "Amplo Espectro"
    default: mode = "Padrão"
    }
    print("Modo de microfone: \(mode)")
    if AVCaptureDevice.activeMicrophoneMode != .voiceIsolation {
        print("Abrindo o seletor de modo — escolha 'Isolamento de Voz'.")
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }
}

// Medidor e verificação de que o microfone está entregando áudio
var silentSeconds = 0
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + 1, repeating: 1)
timer.setEventHandler {
    let frames = meter.frames
    let peak = meter.peakDB
    meter.frames = 0
    meter.peakDB = -120
    if frames == 0 {
        silentSeconds += 1
        if silentSeconds == 3 {
            // Microfone sumiu: encerra para o sistema reiniciar e reconectar quando ele voltar
            print("Nenhum áudio chegando do '\(cfg.source)' há 3 s (desconectado?). Encerrando.")
            exit(3)
        }
        return
    }
    silentSeconds = 0
    if cfg.meter {
        print(String(format: "nível %6.1f dBFS   gate %@", peak, gate.isOpen ? "aberto" : "fechado"))
    }
}
timer.resume()

NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                       object: playEngine, queue: .main) { _ in
    print("A configuração de áudio mudou. Encerrando — rode de novo.")
    exit(2)
}

signal(SIGINT, SIG_IGN)
let sigSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigSrc.setEventHandler {
    capture.stop()
    playEngine.stop()
    print("\nEncerrado.")
    exit(0)
}
sigSrc.resume()

dispatchMain()
