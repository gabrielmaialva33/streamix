/**
 * Player Diagnostics System
 *
 * Netflix-inspired automatic diagnostics that tests configurations
 * when playback errors occur to find a working solution.
 *
 * Key features:
 * - Runs diagnostic tests when errors occur
 * - Tests different player configurations
 * - Finds working configuration automatically
 * - Saves successful config for future use
 * - Provides manual diagnostics for users
 */

import {detectAudioCodecs, detectMSESupport, detectVideoCodecs, getCapabilitySummary,} from "./codec_detector";
import {getRecommendedPlayer} from "./player_preferences";

// Diagnostic test types
const DiagnosticTest = {
    MSE_SUPPORT: "mse_support",
    VIDEO_ELEMENT: "video_element",
    AUDIO_CONTEXT: "audio_context",
    HLS_SUPPORT: "hls_support",
    NATIVE_HLS: "native_hls",
    MPEGTS_SUPPORT: "mpegts_support",
    WASM_SUPPORT: "wasm_support",
    CODEC_H264: "codec_h264",
    CODEC_HEVC: "codec_hevc",
    CODEC_VP9: "codec_vp9",
    CODEC_AV1: "codec_av1",
    AUDIO_AAC: "audio_aac",
    AUDIO_AC3: "audio_ac3",
    AUDIO_OPUS: "audio_opus",
    HARDWARE_ACCEL: "hardware_accel",
    NETWORK: "network",
};

// Test results storage key
const DIAGNOSTICS_KEY = "streamix_diagnostics_results";

/**
 * Run a single diagnostic test
 */
async function runTest(testType) {
    const startTime = performance.now();

    try {
        let result;

        switch (testType) {
            case DiagnosticTest.MSE_SUPPORT:
                result = testMSESupport();
                break;
            case DiagnosticTest.VIDEO_ELEMENT:
                result = testVideoElement();
                break;
            case DiagnosticTest.AUDIO_CONTEXT:
                result = await testAudioContext();
                break;
            case DiagnosticTest.HLS_SUPPORT:
                result = testHLSSupport();
                break;
            case DiagnosticTest.NATIVE_HLS:
                result = testNativeHLS();
                break;
            case DiagnosticTest.MPEGTS_SUPPORT:
                result = testMpegTSSupport();
                break;
            case DiagnosticTest.WASM_SUPPORT:
                result = await testWASMSupport();
                break;
            case DiagnosticTest.CODEC_H264:
                result = testCodec("h264");
                break;
            case DiagnosticTest.CODEC_HEVC:
                result = testCodec("hevc");
                break;
            case DiagnosticTest.CODEC_VP9:
                result = testCodec("vp9");
                break;
            case DiagnosticTest.CODEC_AV1:
                result = testCodec("av1");
                break;
            case DiagnosticTest.AUDIO_AAC:
                result = testAudioCodec("aac");
                break;
            case DiagnosticTest.AUDIO_AC3:
                result = testAudioCodec("ac3");
                break;
            case DiagnosticTest.AUDIO_OPUS:
                result = testAudioCodec("opus");
                break;
            case DiagnosticTest.HARDWARE_ACCEL:
                result = testHardwareAcceleration();
                break;
            case DiagnosticTest.NETWORK:
                result = await testNetwork();
                break;
            default:
                result = {passed: false, error: "Unknown test type"};
        }

        return {
            test: testType,
            passed: result.passed,
            details: result.details || null,
            error: result.error || null,
            duration: Math.round(performance.now() - startTime),
        };
    } catch (error) {
        return {
            test: testType,
            passed: false,
            error: error.message,
            duration: Math.round(performance.now() - startTime),
        };
    }
}

// Individual test implementations

function testMSESupport() {
    const mse = detectMSESupport();
    return {
        passed: mse.supported,
        details: {supportedCodecs: mse.codecs.length},
    };
}

function testVideoElement() {
    try {
        const video = document.createElement("video");
        const canPlay = typeof video.play === "function";
        const hasSource = typeof video.src !== "undefined";

        return {
            passed: canPlay && hasSource,
            details: {canPlay, hasSource},
        };
    } catch (e) {
        return {passed: false, error: e.message};
    }
}

async function testAudioContext() {
    try {
        const AudioCtx = window.AudioContext || window.webkitAudioContext;
        if (!AudioCtx) {
            return {passed: false, details: {reason: "AudioContext not available"}};
        }

        const ctx = new AudioCtx();
        const state = ctx.state;

        // Try to resume if suspended
        if (state === "suspended") {
            try {
                await ctx.resume();
            } catch {
                // Can't resume without user interaction, but that's OK
            }
        }

        await ctx.close();

        return {
            passed: true,
            details: {initialState: state},
        };
    } catch (e) {
        return {passed: false, error: e.message};
    }
}

function testHLSSupport() {
    // Check if Hls.js is loaded and supported
    const hlsLoaded = typeof window.Hls !== "undefined";
    const hlsSupported = hlsLoaded && window.Hls.isSupported?.();

    return {
        passed: hlsSupported,
        details: {loaded: hlsLoaded, supported: hlsSupported},
    };
}

function testNativeHLS() {
    const video = document.createElement("video");
    const canPlay = video.canPlayType("application/vnd.apple.mpegurl");

    return {
        passed: canPlay === "probably" || canPlay === "maybe",
        details: {canPlayType: canPlay},
    };
}

function testMpegTSSupport() {
    // Check if mpegts.js is loaded and MSE is supported
    const mpegtsLoaded = typeof window.mpegts !== "undefined";
    const mseSupported = "MediaSource" in window;

    return {
        passed: mpegtsLoaded && mseSupported,
        details: {mpegtsLoaded, mseSupported},
    };
}

async function testWASMSupport() {
    try {
        // Test basic WebAssembly support
        const wasmSupported = typeof WebAssembly === "object";
        if (!wasmSupported) {
            return {passed: false, details: {reason: "WebAssembly not available"}};
        }

        // Test instantiation with a minimal WASM module
        const wasmCode = new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0]);
        const module = await WebAssembly.compile(wasmCode);
        const instance = await WebAssembly.instantiate(module);

        return {
            passed: !!instance,
            details: {instantiation: "success"},
        };
    } catch (e) {
        return {passed: false, error: e.message};
    }
}

function testCodec(codec) {
    const codecs = detectVideoCodecs();
    const result = codecs[codec];

    return {
        passed: result?.supported || false,
        details: {mime: result?.mime},
    };
}

function testAudioCodec(codec) {
    const codecs = detectAudioCodecs();
    const result = codecs[codec];

    return {
        passed: result?.supported || false,
        details: {mime: result?.mime},
    };
}

function testHardwareAcceleration() {
    try {
        const canvas = document.createElement("canvas");
        const gl = canvas.getContext("webgl") || canvas.getContext("experimental-webgl");

        if (!gl) {
            return {passed: false, details: {reason: "WebGL not available"}};
        }

        const debugInfo = gl.getExtension("WEBGL_debug_renderer_info");
        const renderer = debugInfo ? gl.getParameter(debugInfo.UNMASKED_RENDERER_WEBGL) : "unknown";

        // Check if it's a software renderer
        const isSoftware =
            renderer.toLowerCase().includes("swiftshader") ||
            renderer.toLowerCase().includes("llvmpipe") ||
            renderer.toLowerCase().includes("software");

        return {
            passed: !isSoftware,
            details: {renderer, isSoftware},
        };
    } catch (e) {
        return {passed: false, error: e.message};
    }
}

async function testNetwork() {
    try {
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 5000);

        const startTime = performance.now();
        const response = await fetch("/favicon.ico", {
            method: "HEAD",
            cache: "no-store",
            signal: controller.signal,
        });
        clearTimeout(timeoutId);

        const latency = Math.round(performance.now() - startTime);

        return {
            passed: response.ok,
            details: {latency, status: response.status},
        };
    } catch (e) {
        return {passed: false, error: e.message};
    }
}

/**
 * Run all diagnostic tests
 */
export async function runAllDiagnostics(options = {}) {
    const {onProgress} = options;
    const tests = Object.values(DiagnosticTest);
    const results = [];

    for (let i = 0; i < tests.length; i++) {
        const test = tests[i];

        if (onProgress) {
            onProgress({
                current: i + 1,
                total: tests.length,
                test,
            });
        }

        const result = await runTest(test);
        results.push(result);
    }

    const summary = {
        timestamp: Date.now(),
        totalTests: tests.length,
        passed: results.filter((r) => r.passed).length,
        failed: results.filter((r) => !r.passed).length,
        results,
        recommendations: generateRecommendations(results),
        capabilities: getCapabilitySummary(),
    };

    // Save results
    saveDiagnosticResults(summary);

    return summary;
}

/**
 * Run quick diagnostics (essential tests only)
 */
export async function runQuickDiagnostics() {
    const essentialTests = [
        DiagnosticTest.VIDEO_ELEMENT,
        DiagnosticTest.MSE_SUPPORT,
        DiagnosticTest.CODEC_H264,
        DiagnosticTest.AUDIO_AAC,
        DiagnosticTest.NETWORK,
    ];

    const results = await Promise.all(essentialTests.map((t) => runTest(t)));

    return {
        timestamp: Date.now(),
        totalTests: essentialTests.length,
        passed: results.filter((r) => r.passed).length,
        failed: results.filter((r) => !r.passed).length,
        results,
        allPassed: results.every((r) => r.passed),
    };
}

/**
 * Generate recommendations based on test results
 */
function generateRecommendations(results) {
    const recommendations = [];
    const failed = results.filter((r) => !r.passed);

    for (const result of failed) {
        switch (result.test) {
            case DiagnosticTest.MSE_SUPPORT:
                recommendations.push({
                    priority: "high",
                    issue: "MediaSource Extensions not supported",
                    action: "Try using Safari which has native HLS support, or update your browser",
                });
                break;

            case DiagnosticTest.AUDIO_AC3:
                recommendations.push({
                    priority: "medium",
                    issue: "AC3/Dolby Digital audio not natively supported",
                    action: "Enable Audio Compatibility mode in player settings for MKV files",
                });
                break;

            case DiagnosticTest.WASM_SUPPORT:
                recommendations.push({
                    priority: "high",
                    issue: "WebAssembly not available",
                    action: "Update your browser to a recent version for best compatibility",
                });
                break;

            case DiagnosticTest.NETWORK:
                recommendations.push({
                    priority: "high",
                    issue: "Network connectivity issues",
                    action: "Check your internet connection and try again",
                });
                break;

            case DiagnosticTest.HARDWARE_ACCEL:
                recommendations.push({
                    priority: "low",
                    issue: "Hardware acceleration may be disabled",
                    action: "Enable hardware acceleration in browser settings for better performance",
                });
                break;
        }
    }

    // Sort by priority
    const priorityOrder = {high: 0, medium: 1, low: 2};
    recommendations.sort((a, b) => priorityOrder[a.priority] - priorityOrder[b.priority]);

    return recommendations;
}

/**
 * Run diagnostics for a specific error
 */
export async function diagnoseError(error, context = {}) {
    // Determine which tests to run based on error type
    let testsToRun = [];

    const errorStr = String(error?.message || error || "").toLowerCase();

    if (errorStr.includes("network") || errorStr.includes("fetch")) {
        testsToRun.push(DiagnosticTest.NETWORK);
    }

    if (errorStr.includes("codec") || errorStr.includes("decode") || errorStr.includes("format")) {
        testsToRun.push(
            DiagnosticTest.CODEC_H264,
            DiagnosticTest.CODEC_HEVC,
            DiagnosticTest.AUDIO_AAC,
            DiagnosticTest.AUDIO_AC3,
            DiagnosticTest.WASM_SUPPORT,
        );
    }

    if (errorStr.includes("audio")) {
        testsToRun.push(
            DiagnosticTest.AUDIO_CONTEXT,
            DiagnosticTest.AUDIO_AAC,
            DiagnosticTest.AUDIO_AC3,
            DiagnosticTest.AUDIO_OPUS,
        );
    }

    if (errorStr.includes("media") || errorStr.includes("source")) {
        testsToRun.push(
            DiagnosticTest.MSE_SUPPORT,
            DiagnosticTest.VIDEO_ELEMENT,
            DiagnosticTest.HLS_SUPPORT,
        );
    }

    // If no specific tests, run essential ones
    if (testsToRun.length === 0) {
        testsToRun = [
            DiagnosticTest.VIDEO_ELEMENT,
            DiagnosticTest.MSE_SUPPORT,
            DiagnosticTest.NETWORK,
            DiagnosticTest.AUDIO_CONTEXT,
        ];
    }

    // Remove duplicates
    testsToRun = [...new Set(testsToRun)];

    const results = await Promise.all(testsToRun.map((t) => runTest(t)));

    return {
        error: error?.message || String(error),
        context,
        testsRun: testsToRun.length,
        results,
        recommendations: generateRecommendations(results),
        suggestedPlayer: suggestPlayer(results, context),
    };
}

/**
 * Suggest the best player configuration based on diagnostics
 */
function suggestPlayer(results, context = {}) {
    // Check for existing recommendation
    const contentType = context.contentType || context.streamType || "unknown";
    const recommended = getRecommendedPlayer(contentType);

    if (recommended) {
        return {
            player: recommended,
            reason: "Based on previous successful playback",
            confidence: "high",
        };
    }

    // Analyze test results
    const testMap = {};
    for (const result of results) {
        testMap[result.test] = result.passed;
    }

    // If AC3/advanced audio failed, suggest AVPlayer
    if (
        testMap[DiagnosticTest.AUDIO_AC3] === false &&
        testMap[DiagnosticTest.WASM_SUPPORT] !== false
    ) {
        return {
            player: "avplayer",
            reason: "Advanced audio codecs require WASM decoder",
            confidence: "high",
        };
    }

    // If MSE not supported, suggest native
    if (testMap[DiagnosticTest.MSE_SUPPORT] === false) {
        return {
            player: "native",
            reason: "MediaSource Extensions not available",
            confidence: "medium",
        };
    }

    // Default to native for HLS, with fallbacks
    return {
        player: "native",
        reason: "Default configuration",
        confidence: "medium",
        fallbacks: ["hls", "mpegts", "avplayer"],
    };
}

/**
 * Save diagnostic results to localStorage
 */
function saveDiagnosticResults(summary) {
    try {
        localStorage.setItem(DIAGNOSTICS_KEY, JSON.stringify(summary));
    } catch (e) {
        console.warn("[PlayerDiagnostics] Failed to save results:", e);
    }
}

/**
 * Load previous diagnostic results
 */
export function loadDiagnosticResults() {
    try {
        const stored = localStorage.getItem(DIAGNOSTICS_KEY);
        return stored ? JSON.parse(stored) : null;
    } catch {
        return null;
    }
}

/**
 * Clear saved diagnostic results
 */
export function clearDiagnosticResults() {
    try {
        localStorage.removeItem(DIAGNOSTICS_KEY);
    } catch (e) {
        console.warn("[PlayerDiagnostics] Failed to clear results:", e);
    }
}

/**
 * Format diagnostic results for display
 */
export function formatDiagnosticsForDisplay(summary) {
    const lines = [];

    lines.push("=== Player Diagnostics ===");
    lines.push(`Ran ${summary.totalTests} tests: ${summary.passed} passed, ${summary.failed} failed`);
    lines.push("");

    for (const result of summary.results) {
        const status = result.passed ? "✓" : "✗";
        const name = result.test.replace(/_/g, " ");
        lines.push(`${status} ${name}${result.error ? ` (${result.error})` : ""}`);
    }

    if (summary.recommendations.length > 0) {
        lines.push("");
        lines.push("Recommendations:");
        for (const rec of summary.recommendations) {
            lines.push(`• [${rec.priority.toUpperCase()}] ${rec.action}`);
        }
    }

    return lines.join("\n");
}

export {DiagnosticTest};

export default {
    runAllDiagnostics,
    runQuickDiagnostics,
    diagnoseError,
    loadDiagnosticResults,
    clearDiagnosticResults,
    formatDiagnosticsForDisplay,
    DiagnosticTest,
};
