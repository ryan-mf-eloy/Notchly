import Metal
import MetalKit
import QuartzCore
import simd
import SwiftUI

struct AppleMetalWaveformRenderer {
    private static let validatedAvailability: Bool = {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return (try? AppleMetalWaveformView.makePipelineState(device: device)) != nil
    }()

    var isAvailable: Bool {
        Self.validatedAvailability
    }
}

struct AppleMetalWaveformView: NSViewRepresentable {
    var intensity: Float = 1
    var levels: [CGFloat] = []

    func makeCoordinator() -> Renderer {
        Renderer(intensity: intensity, levels: levels)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        guard let device = MTLCreateSystemDefaultDevice(),
              let pipelineState = try? Self.makePipelineState(device: device) else {
            return view
        }

        view.device = device
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 120
        context.coordinator.configure(device: device, pipelineState: pipelineState)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.update(intensity: intensity, levels: levels)
    }

    nonisolated fileprivate static func makePipelineState(device: MTLDevice) throws -> MTLRenderPipelineState {
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "notchWaveVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "notchWaveFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    nonisolated private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct Uniforms {
        float time;
        float2 viewport;
        float intensity;
        float peak;
        float flux;
    };

    vertex VertexOut notchWaveVertex(uint vertexID [[vertex_id]]) {
        float2 positions[6] = {
            float2(-1.0, -1.0),
            float2( 1.0, -1.0),
            float2(-1.0,  1.0),
            float2( 1.0, -1.0),
            float2( 1.0,  1.0),
            float2(-1.0,  1.0)
        };

        float2 p = positions[vertexID];
        VertexOut out;
        out.position = float4(p, 0.0, 1.0);
        out.uv = p * 0.5 + 0.5;
        return out;
    }

    static float hash21(float2 p) {
        p = fract(p * float2(123.34, 345.45));
        p += dot(p, p + 34.345);
        return fract(p.x * p.y);
    }

    static float noise2(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);

        float a = hash21(i);
        float b = hash21(i + float2(1.0, 0.0));
        float c = hash21(i + float2(0.0, 1.0));
        float d = hash21(i + float2(1.0, 1.0));

        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }

    static float fbm(float2 p) {
        float value = 0.0;
        float amplitude = 0.52;
        for (int i = 0; i < 4; i++) {
            value += amplitude * noise2(p);
            p = p * 2.06 + float2(13.17, 8.31);
            amplitude *= 0.48;
        }
        return value;
    }

    static float waveLine(float y, float center, float width) {
        float d = abs(y - center);
        return exp(-(d * d) / width);
    }

    fragment float4 notchWaveFragment(VertexOut in [[stage_in]],
                                      constant Uniforms& uniforms [[buffer(0)]]) {
        float2 uv = in.uv;
        float t = uniforms.time;
        float x = uv.x;
        float y = uv.y;
        float viewportWidth = max(uniforms.viewport.x, 1.0);
        float viewportHeight = max(uniforms.viewport.y, 1.0);
        float px = uv.x * viewportWidth;
        float py = uv.y * viewportHeight;
        float intensity = clamp(uniforms.intensity, 0.0, 1.0);
        float peak = clamp(uniforms.peak, 0.0, 1.0);
        float flux = clamp(uniforms.flux, 0.0, 1.0);

        float sideFade = smoothstep(0.0, 0.006, x) * (1.0 - smoothstep(0.994, 1.0, x));
        float center = 0.50;
        float centerPx = center * viewportHeight;
        float waveformMask = sideFade;

        float barStep = 5.2;
        float column = floor(px / barStep);
        float barCenterX = (column + 0.5) * barStep;

        float seed = hash21(float2(column, 4.73));
        float speed = 0.54 + intensity * 1.10 + flux * 0.56;
        float waveA = 0.5 + 0.5 * sin(column * 0.29 + t * (1.22 + speed));
        float waveB = 0.5 + 0.5 * sin(column * 0.61 - t * (0.78 + speed * 0.72) + seed * 5.7);
        float waveC = 0.5 + 0.5 * sin(column * 0.13 + t * (0.44 + speed * 0.38));
        float grain = fbm(float2(column * 0.13 + t * 0.32, t * 0.18 + seed * 2.0));
        float shape = clamp(waveA * 0.36 + waveB * 0.30 + waveC * 0.18 + grain * 0.16, 0.0, 1.0);

        float centerLift = smoothstep(0.0, 0.16, x) * (1.0 - smoothstep(0.84, 1.0, x));
        float edgeAmplitude = 0.34 + 0.66 * centerLift;
        float phrase = 0.80 + 0.20 * sin(x * 22.0 - t * (0.52 + flux * 0.44));
        float reactivity = 0.16 + intensity * 0.68 + peak * 0.22 + flux * 0.16;
        float transient = smoothstep(0.52, 1.0, peak) * smoothstep(0.18, 1.0, shape);
        float amp = (0.030 + shape * 0.31 + transient * 0.055) * reactivity * edgeAmplitude * phrase;
        amp = min(amp, 0.42);

        float halfWidth = 1.05;
        float halfHeight = max(1.8, amp * viewportHeight);
        float radius = 1.65;
        float2 q = abs(float2(px - barCenterX, py - centerPx)) - float2(halfWidth, halfHeight) + radius;
        float roundedBarDistance = length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
        float bars = (1.0 - smoothstep(0.0, 1.15, roundedBarDistance)) * waveformMask;

        float axis = (1.0 - smoothstep(0.0018, 0.0068, abs(y - center))) * sideFade;
        axis *= 0.040 * (0.18 + intensity);

        float glow = bars * 0.10 * (0.35 + intensity + peak * 0.45);
        float alpha = clamp(bars * (0.56 + intensity * 0.14 + peak * 0.10) + axis + glow, 0.0, 0.76);

        float3 graphite = float3(0.34, 0.34, 0.34);
        float3 pearl = float3(0.90, 0.90, 0.87);
        float brightness = clamp(0.34 + shape * 0.42 + intensity * 0.18 + peak * 0.12, 0.0, 1.0);
        float3 color = mix(graphite, pearl, brightness);

        return float4(color, alpha);
    }
    """

    final class Renderer: NSObject, MTKViewDelegate {
        private var commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?
        private let startTime = CACurrentMediaTime()
        private var targetIntensity: Float
        private var targetPeak: Float
        private var targetFlux: Float
        private var smoothedIntensity: Float
        private var smoothedPeak: Float
        private var smoothedFlux: Float

        init(intensity: Float, levels: [CGFloat]) {
            let signal = Self.signal(from: intensity, levels: levels)
            self.targetIntensity = signal.average
            self.targetPeak = signal.peak
            self.targetFlux = signal.flux
            self.smoothedIntensity = signal.average
            self.smoothedPeak = signal.peak
            self.smoothedFlux = signal.flux
        }

        func configure(device: MTLDevice, pipelineState: MTLRenderPipelineState) {
            self.commandQueue = device.makeCommandQueue()
            self.pipelineState = pipelineState
        }

        func update(intensity: Float, levels: [CGFloat]) {
            let signal = Self.signal(from: intensity, levels: levels)
            targetIntensity = signal.average
            targetPeak = signal.peak
            targetFlux = signal.flux
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let pipelineState,
                  let commandQueue,
                  let descriptor = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

            smoothSignals()

            var uniforms = Uniforms(
                time: Float(CACurrentMediaTime() - startTime),
                viewport: SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height)),
                intensity: smoothedIntensity,
                peak: smoothedPeak,
                flux: smoothedFlux
            )

            encoder.setRenderPipelineState(pipelineState)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        private func smoothSignals() {
            smoothedIntensity = smooth(current: smoothedIntensity, target: targetIntensity, attack: 0.24, release: 0.075)
            smoothedPeak = smooth(current: smoothedPeak, target: targetPeak, attack: 0.34, release: 0.11)
            smoothedFlux = smooth(current: smoothedFlux, target: targetFlux, attack: 0.28, release: 0.06)
        }

        private func smooth(current: Float, target: Float, attack: Float, release: Float) -> Float {
            let factor = target > current ? attack : release
            return current + (target - current) * factor
        }

        private static func signal(from intensity: Float, levels: [CGFloat]) -> (average: Float, peak: Float, flux: Float) {
            let recent = levels.suffix(12).map { Float($0) }
            guard !recent.isEmpty else {
                let clamped = min(max(intensity, 0.04), 1)
                return (clamped, clamped, 0)
            }

            let average = recent.reduce(0, +) / Float(recent.count)
            let peak = recent.max() ?? average
            let last = recent.last ?? average
            let previous = recent.dropLast().last ?? average
            let flux = min(max(abs(last - previous) * 1.8 + max(last - average, 0) * 0.8, 0), 1)
            let blended = min(max(average * 0.62 + peak * 0.26 + intensity * 0.22, 0.035), 1)
            return (blended, min(max(peak, 0.035), 1), flux)
        }
    }
}

struct AppleMetalFlowMarkRenderer {
    private static let validatedAvailability: Bool = {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return (try? AppleMetalFlowMarkView.makePipelineState(device: device)) != nil
    }()

    var isAvailable: Bool {
        Self.validatedAvailability
    }
}

struct AppleMetalFlowMarkView: NSViewRepresentable {
    var levels: [CGFloat] = []
    var isPaused: Bool = false
    var reduceMotion: Bool = false
    var accent: WhiprFlowAudioAccent = .neutral

    func makeCoordinator() -> Renderer {
        Renderer(levels: levels, isPaused: isPaused, reduceMotion: reduceMotion, accent: accent)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        guard let device = MTLCreateSystemDefaultDevice(),
              let pipelineState = try? Self.makePipelineState(device: device) else {
            return view
        }

        view.device = device
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 120
        context.coordinator.configure(device: device, pipelineState: pipelineState)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.update(levels: levels, isPaused: isPaused, reduceMotion: reduceMotion, accent: accent)
    }

    nonisolated fileprivate static func makePipelineState(device: MTLDevice) throws -> MTLRenderPipelineState {
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "notchFlowMarkVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "notchFlowMarkFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    nonisolated private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct FlowVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct FlowUniforms {
        float time;
        float2 viewport;
        float intensity;
        float peak;
        float flux;
        float4 bandsA;
        float4 bandsB;
        float4 bandsC;
        float bandD;
        float paused;
        float reduceMotion;
        float accent;
    };

    vertex FlowVertexOut notchFlowMarkVertex(uint vertexID [[vertex_id]]) {
        float2 positions[6] = {
            float2(-1.0, -1.0),
            float2( 1.0, -1.0),
            float2(-1.0,  1.0),
            float2( 1.0, -1.0),
            float2( 1.0,  1.0),
            float2(-1.0,  1.0)
        };

        float2 p = positions[vertexID];
        FlowVertexOut out;
        out.position = float4(p, 0.0, 1.0);
        out.uv = p * 0.5 + 0.5;
        return out;
    }

    static float flowBandAt(int index, float4 bandsA, float4 bandsB, float4 bandsC, float bandD) {
        if (index == 0) { return bandsA.x; }
        if (index == 1) { return bandsA.y; }
        if (index == 2) { return bandsA.z; }
        if (index == 3) { return bandsA.w; }
        if (index == 4) { return bandsB.x; }
        if (index == 5) { return bandsB.y; }
        if (index == 6) { return bandsB.z; }
        if (index == 7) { return bandsB.w; }
        if (index == 8) { return bandsC.x; }
        if (index == 9) { return bandsC.y; }
        if (index == 10) { return bandsC.z; }
        if (index == 11) { return bandsC.w; }
        return bandD;
    }

    static float flowResponsiveness(int index) {
        float values[13] = { 0.34, 0.58, 0.40, 0.78, 0.52, 0.92, 0.70, 0.88, 0.50, 0.74, 0.38, 0.54, 0.32 };
        return values[index];
    }

    static float flowHash11(float n) {
        return fract(sin(n * 127.1) * 43758.5453123);
    }

    static float roundedBoxDistance(float2 p, float2 halfSize, float radius) {
        float2 q = abs(p) - halfSize + radius;
        return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
    }

    fragment float4 notchFlowMarkFragment(FlowVertexOut in [[stage_in]],
                                          constant FlowUniforms& uniforms [[buffer(0)]]) {
        float2 viewport = max(uniforms.viewport, float2(1.0));
        float2 px = in.uv * viewport;
        float2 center = viewport * 0.5;
        float scale = min(viewport.x / 56.0, viewport.y / 18.0);
        float intensity = clamp(uniforms.intensity, 0.0, 1.0);
        float peak = clamp(uniforms.peak, 0.0, 1.0);
        float flux = clamp(uniforms.flux, 0.0, 1.0);
        float paused = clamp(uniforms.paused, 0.0, 1.0);
        float active = 1.0 - paused;
        float energy = active * clamp(intensity * 0.76 + peak * 0.22 + flux * 0.16, 0.0, 1.0);
        float motion = active * (1.0 - clamp(uniforms.reduceMotion, 0.0, 1.0)) * smoothstep(0.02, 0.24, intensity + peak * 0.30);

        float alpha = 0.0;
        float3 color = float3(0.48, 0.48, 0.47);
        float spacing = 4.02 * scale;

        for (int index = 0; index < 13; index++) {
            float band = clamp(flowBandAt(index, uniforms.bandsA, uniforms.bandsB, uniforms.bandsC, uniforms.bandD), 0.0, 1.0);
            float leftBand = index > 0
                ? clamp(flowBandAt(index - 1, uniforms.bandsA, uniforms.bandsB, uniforms.bandsC, uniforms.bandD), 0.0, 1.0)
                : band;
            float rightBand = index < 12
                ? clamp(flowBandAt(index + 1, uniforms.bandsA, uniforms.bandsB, uniforms.bandsC, uniforms.bandD), 0.0, 1.0)
                : band;
            float neighborAverage = (leftBand + rightBand) * 0.5;
            float localContrast = max(0.0, band - neighborAverage);
            float response = flowResponsiveness(index);
            float phase = float(index) * 1.6180339;
            float seed = flowHash11(float(index) + 1.73);
            float speedLift = 1.0 + peak * 0.72 + intensity * 0.42;
            float driftA = sin(uniforms.time * (0.54 + response * 0.42) * speedLift + phase + seed * 0.70);
            float driftB = sin(uniforms.time * (0.92 + float(index % 5) * 0.09) * speedLift - phase * 0.73);
            float driftC = sin(uniforms.time * (0.30 + flux * 0.28) * speedLift + phase * 2.37 + seed * 0.45);
            float centerDistance = abs(float(index) - 6.0) / 12.0;
            float centerWeight = 1.0 - centerDistance * 0.28;
            float audioWeight = 0.32 + intensity * 0.86 + peak * 0.22;
            float organicOffset = (driftA * 0.070 + driftB * 0.045 + driftC * 0.030) * motion * audioWeight;
            float contrastOffset = localContrast * driftB * 0.055 * motion;
            band = clamp(band * (0.96 + centerWeight * 0.045) + organicOffset + contrastOffset, 0.0, 1.0);
            float loudness = smoothstep(0.56, 0.96, max(intensity, peak));
            float fastLift = 1.0 + peak * 0.92 + intensity * 0.58;
            float compressedBand = band <= 0.72 ? band : 0.72 + (band - 0.72) * 0.56;
            float rippleA = sin(uniforms.time * (1.36 + response * 0.72) * fastLift + float(index) * 1.93) * 0.082;
            float rippleB = sin(uniforms.time * (2.10 + float(index % 4) * 0.16) * fastLift - float(index) * 1.1773) * 0.034;
            float dynamicCeiling = 0.91 + sin(uniforms.time * (1.02 + response * 0.36) * fastLift + float(index) * 0.9071) * 0.046;
            band = clamp(min(compressedBand + (rippleA + rippleB) * loudness * motion, dynamicCeiling), 0.02, 0.98);
            float shapedBand = pow(band, 0.48);

            float liveLift = active * shapedBand * (2.15 + response * 10.65);
            float transientLift = active * flux * (0.35 + response * 1.80) * (0.45 + shapedBand * 0.55 + localContrast);
            float globalLift = active * intensity * (0.35 + response * 0.65);
            float height = clamp(4.2 + liveLift + transientLift + globalLift, 4.2, 17.2) * scale;

            float width = min(2.95, 1.72 + active * (pow(band, 0.62) * 0.46 + localContrast * 0.18 + flux * response * 0.05)) * scale;
            float x = (float(index) - 6.0) * spacing;
            float yJitter = sin(uniforms.time * (0.62 + response * 0.32) * speedLift + float(index) * 2.11) * 0.52;
            yJitter *= (1.0 - centerDistance * 0.35) * motion * (0.30 + intensity * 0.70) * scale;
            float2 barCenter = center + float2(x, yJitter);

            float distance = roundedBoxDistance(px - barCenter, float2(width * 0.5, height * 0.5), width * 0.5);
            float coverage = 1.0 - smoothstep(0.0, 0.95, distance);
            float barAlpha = coverage * mix(0.34,
                                            min(1.0, 0.34 + energy * 0.26 + shapedBand * 0.29 + localContrast * 0.08 + flux * response * 0.10),
                                            active);

            float3 restGray = float3(0.48, 0.48, 0.47);
            float3 white = float3(0.98, 0.98, 0.95);
            float tintAmount = min(1.0, shapedBand * 0.52 + intensity * 0.32 + peak * 0.12 + flux * response * 0.12);
            float3 neutralColor = mix(restGray, white, active * tintAmount);
            float3 questionGreen = float3(0.34, 0.88, 0.52);
            float3 restingGreen = mix(restGray, questionGreen, 0.44);
            float3 brightGreen = mix(questionGreen, white, 0.16);
            float3 activeGreen = mix(restingGreen, brightGreen, tintAmount);
            float3 barColor = mix(neutralColor, activeGreen, active * clamp(uniforms.accent, 0.0, 1.0));

            if (barAlpha > alpha) {
                alpha = barAlpha;
                color = barColor;
            }

            float halo = (1.0 - smoothstep(0.8, 4.2, distance)) * energy * (0.010 + intensity * 0.020 + flux * 0.016);
            alpha = max(alpha, halo);
        }

        return float4(color, alpha);
    }
    """

    final class Renderer: NSObject, MTKViewDelegate {
        private var commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?
        private let startTime = CACurrentMediaTime()
        private var target = WhiprFlowAudioSignal.empty
        private var smoothed = WhiprFlowAudioSignal.empty
        private var isPaused: Bool
        private var reduceMotion: Bool
        private var accent: WhiprFlowAudioAccent

        init(levels: [CGFloat], isPaused: Bool, reduceMotion: Bool, accent: WhiprFlowAudioAccent) {
            let signal = WhiprFlowAudioMark.signal(for: levels, isPaused: isPaused)
            self.target = signal
            self.smoothed = signal
            self.isPaused = isPaused
            self.reduceMotion = reduceMotion
            self.accent = accent
        }

        func configure(device: MTLDevice, pipelineState: MTLRenderPipelineState) {
            self.commandQueue = device.makeCommandQueue()
            self.pipelineState = pipelineState
        }

        func update(levels: [CGFloat], isPaused: Bool, reduceMotion: Bool, accent: WhiprFlowAudioAccent) {
            target = WhiprFlowAudioMark.signal(for: levels, isPaused: isPaused)
            self.isPaused = isPaused
            self.reduceMotion = reduceMotion
            self.accent = accent
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let pipelineState,
                  let commandQueue,
                  let descriptor = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

            smoothSignals()

            var uniforms = FlowMarkUniforms(
                time: Float(CACurrentMediaTime() - startTime),
                viewport: SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height)),
                intensity: Float(smoothed.average),
                peak: Float(smoothed.peak),
                flux: Float(smoothed.flux),
                bandsA: SIMD4<Float>(Float(smoothed.bands[0]), Float(smoothed.bands[1]), Float(smoothed.bands[2]), Float(smoothed.bands[3])),
                bandsB: SIMD4<Float>(Float(smoothed.bands[4]), Float(smoothed.bands[5]), Float(smoothed.bands[6]), Float(smoothed.bands[7])),
                bandsC: SIMD4<Float>(Float(smoothed.bands[8]), Float(smoothed.bands[9]), Float(smoothed.bands[10]), Float(smoothed.bands[11])),
                bandD: Float(smoothed.bands[12]),
                paused: isPaused ? 1 : 0,
                reduceMotion: reduceMotion ? 1 : 0,
                accent: accent == .questionActive ? 1 : 0
            )

            encoder.setRenderPipelineState(pipelineState)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FlowMarkUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        private func smoothSignals() {
            smoothed.average = smooth(current: smoothed.average, target: target.average, attack: 0.28, release: 0.12)
            smoothed.peak = smooth(current: smoothed.peak, target: target.peak, attack: 0.36, release: 0.14)
            smoothed.flux = smooth(current: smoothed.flux, target: target.flux, attack: 0.40, release: 0.20)
            for index in smoothed.bands.indices {
                smoothed.bands[index] = smooth(current: smoothed.bands[index], target: target.bands[index], attack: 0.30, release: 0.16)
            }
        }

        private func smooth(current: CGFloat, target: CGFloat, attack: CGFloat, release: CGFloat) -> CGFloat {
            let delta = abs(target - current)
            guard delta >= 0.003 else { return target }
            guard !(target == 0 && current < 0.015) else { return 0 }

            let factor = min(1, (target > current ? attack : release) + min(delta * 0.28, 0.08))
            return current + (target - current) * factor
        }
    }
}

private struct Uniforms {
    var time: Float
    var viewport: SIMD2<Float>
    var intensity: Float
    var peak: Float
    var flux: Float
}

private struct FlowMarkUniforms {
    var time: Float
    var viewport: SIMD2<Float>
    var intensity: Float
    var peak: Float
    var flux: Float
    var bandsA: SIMD4<Float>
    var bandsB: SIMD4<Float>
    var bandsC: SIMD4<Float>
    var bandD: Float
    var paused: Float
    var reduceMotion: Float
    var accent: Float
}
