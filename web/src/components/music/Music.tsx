import { useEffect, useRef, useState } from "react";
import { requestYoutubeAudio } from "@/lib/audioTransfer";
type Deck = {
    audio: HTMLAudioElement;
    isPlaying: boolean;
    tempo: number;
    baseBpm: number | null;
    currentTime?: number;
    duration?: number;
    objectUrl?: string;
    deckVolume?: number; // 0..1
    playlist?: PlaylistItem[];
    currentItemId?: string | null;
}

type PlaylistItem = {
    id: string;
    title: string;
    src: string; // url or object URL
    sourceType: "url" | "file";
    baseBpm?: number | null;
};

export default function Music() {
    const [decks, setDecks] = useState<Record<string, Deck>>({});
    const [crossfade, setCrossfade] = useState(0.5); // 0 = left only, 1 = right only
    const [masterVolume, setMasterVolume] = useState(0.6); // overall gain cap

    // Web Audio routing
    const audioCtxRef = useRef<AudioContext | null>(null);
    const nodesRef = useRef<Record<string, { source: MediaElementAudioSourceNode; gain: GainNode; panner: StereoPannerNode }>>({});

    // Monitor state: only one deck at a time; first deck -> Left, second -> Right
    const [monitorDeck, setMonitorDeck] = useState<string | null>(null);

    // Tempo and BPM states
    useEffect(() => {
        const t1 = new Audio("/nui/audio/track_1.mp3");
        const t2 = new Audio("/nui/audio/track_2.mp3");
        t1.loop = true;
        t2.loop = true;
        t1.preload = "auto";
        t2.preload = "auto";
        // Ensure tempo affects pitch (disable pitch preservation where supported)
        try {
            (t1 as any).preservesPitch = false;
            (t1 as any).mozPreservesPitch = false;
            (t1 as any).webkitPreservesPitch = false;
        } catch {}
        try {
            (t2 as any).preservesPitch = false;
            (t2 as any).mozPreservesPitch = false;
            (t2 as any).webkitPreservesPitch = false;
        } catch {}
        const makeInitialItem = (src: string) => ({
            id: `${Date.now()}_${Math.random().toString(36).slice(2)}`,
            title: deriveTitleFromUrlOrName(src),
            src,
            sourceType: "url" as const,
            baseBpm: null,
        });
        const initial1 = makeInitialItem("/nui/audio/track_1.mp3");
        const initial2 = makeInitialItem("/nui/audio/track_2.mp3");

        setDecks({
            track_1: {
                audio: t1,
                isPlaying: false,
                tempo: 1,
                baseBpm: null,
                currentTime: 0,
                duration: 0,
                deckVolume: 1,
                playlist: [initial1],
                currentItemId: initial1.id,
            },
            track_2: {
                audio: t2,
                isPlaying: false,
                tempo: 1,
                baseBpm: null,
                currentTime: 0,
                duration: 0,
                deckVolume: 1,
                playlist: [initial2],
                currentItemId: initial2.id,
            },
        });

        // Create Web Audio graph
        const AudioCtx = (window as any).AudioContext || (window as any).webkitAudioContext;
        const ctx: AudioContext = audioCtxRef.current ?? new AudioCtx();
        audioCtxRef.current = ctx;

        const makeChain = (el: HTMLAudioElement) => {
            const source = ctx.createMediaElementSource(el);
            const gain = ctx.createGain();
            const panner = ctx.createStereoPanner();
            source.connect(gain).connect(panner).connect(ctx.destination);
            return { source, gain, panner };
        };

        nodesRef.current["track_1"] = makeChain(t1);
        nodesRef.current["track_2"] = makeChain(t2);

        // Wire metadata and progress
        const onLoaded1 = () => setDecks(prev => prev.track_1 ? ({ ...prev, track_1: { ...prev.track_1, duration: t1.duration || 0 } }) : prev);
        const onLoaded2 = () => setDecks(prev => prev.track_2 ? ({ ...prev, track_2: { ...prev.track_2, duration: t2.duration || 0 } }) : prev);
        const onTime1 = () => setDecks(prev => prev.track_1 ? ({ ...prev, track_1: { ...prev.track_1, currentTime: t1.currentTime } }) : prev);
        const onTime2 = () => setDecks(prev => prev.track_2 ? ({ ...prev, track_2: { ...prev.track_2, currentTime: t2.currentTime } }) : prev);
        t1.addEventListener("loadedmetadata", onLoaded1);
        t2.addEventListener("loadedmetadata", onLoaded2);
        t1.addEventListener("timeupdate", onTime1);
        t2.addEventListener("timeupdate", onTime2);

        let cancelled = false;
        (async () => {
            const [l, r] = await Promise.all([
                analyzeBpmForUrl("/nui/audio/track_1.mp3"),
                analyzeBpmForUrl("/nui/audio/track_2.mp3"),
            ]);
            if (!cancelled) {
                if (l) setDecks(prev => ({ ...prev, track_1: { ...prev.track_1, baseBpm: l } }));
                if (r) setDecks(prev => ({ ...prev, track_2: { ...prev.track_2, baseBpm: r } }));
            }
        })();
        return () => {
            t1.removeEventListener("loadedmetadata", onLoaded1);
            t2.removeEventListener("loadedmetadata", onLoaded2);
            t1.removeEventListener("timeupdate", onTime1);
            t2.removeEventListener("timeupdate", onTime2);
            t1.pause();
            t2.pause();
            try {
                nodesRef.current["track_1"]?.source.disconnect();
                nodesRef.current["track_1"]?.gain.disconnect();
                nodesRef.current["track_1"]?.panner.disconnect();
                nodesRef.current["track_2"]?.source.disconnect();
                nodesRef.current["track_2"]?.gain.disconnect();
                nodesRef.current["track_2"]?.panner.disconnect();
            } catch {}
            // do not close ctx to avoid pops; it will be GC'ed on page unload
            cancelled = true;
        };
    }, []);

    // Apply equal-power crossfade to gain nodes; also apply playbackRate
    useEffect(() => {
        if (!decks.track_1?.audio || !decks.track_2?.audio) return;
        const n1 = nodesRef.current["track_1"];
        const n2 = nodesRef.current["track_2"];
        const vol1 = decks.track_1.deckVolume ?? 1;
        const vol2 = decks.track_2.deckVolume ?? 1;
        if (monitorDeck) {
            // When monitoring, bypass crossfader balance: both decks at half volume
            const half1 = Math.max(0, Math.min(1, 0.5 * masterVolume * vol1));
            const half2 = Math.max(0, Math.min(1, 0.5 * masterVolume * vol2));
            if (n1) n1.gain.gain.value = half1;
            if (n2) n2.gain.gain.value = half2;
        } else {
            const theta = crossfade * 0.5 * Math.PI;
            const leftGain = Math.cos(theta);
            const rightGain = Math.sin(theta);
            if (n1) n1.gain.gain.value = Math.max(0, Math.min(1, leftGain * masterVolume * vol1));
            if (n2) n2.gain.gain.value = Math.max(0, Math.min(1, rightGain * masterVolume * vol2));
        }
        decks.track_1.audio.playbackRate = decks.track_1.tempo;
        decks.track_2.audio.playbackRate = decks.track_2.tempo;
    }, [decks, crossfade, masterVolume, monitorDeck]);

    // Apply monitor routing via stereo panners
    useEffect(() => {
        const n1 = nodesRef.current["track_1"];
        const n2 = nodesRef.current["track_2"];
        if (!n1 || !n2) return;
        if (!monitorDeck) {
            n1.panner.pan.value = 0;
            n2.panner.pan.value = 0;
            return;
        }
        // track_1 monitored -> hard left, other hard right; track_2 opposite
        const isFirst = monitorDeck === "track_1";
        const monitored = isFirst ? n1 : n2;
        const other = isFirst ? n2 : n1;
        monitored.panner.pan.value = isFirst ? -1 : 1;
        other.panner.pan.value = isFirst ? 1 : -1;
    }, [monitorDeck]);

    // --- BPM Analysis Utilities ---
    async function analyzeBpmForUrl(url: string): Promise<number | null> {
        try {
            const res = await fetch(url);
            const arrayBuffer = await res.arrayBuffer();
            const AudioCtx = (window as any).AudioContext || (window as any).webkitAudioContext;
            const ctx: AudioContext = new AudioCtx();
            const audioBuffer = await ctx.decodeAudioData(arrayBuffer);
            const bpm = estimateBpmFromBuffer(audioBuffer);
            await ctx.close();
            return bpm;
        } catch {
            return null;
        }
    }

    async function analyzeBpmFromBlob(blob: Blob): Promise<number | null> {
        try {
            const arrayBuffer = await blob.arrayBuffer();
            const AudioCtx = (window as any).AudioContext || (window as any).webkitAudioContext;
            const ctx: AudioContext = new AudioCtx();
            const audioBuffer = await ctx.decodeAudioData(arrayBuffer);
            const bpm = estimateBpmFromBuffer(audioBuffer);
            await ctx.close();
            return bpm;
        } catch {
            return null;
        }
    }

    // --- Playlist helpers ---
    const deriveTitleFromUrlOrName = (input: string): string => {
        try {
            const noQuery = input.split("?")[0].split("#")[0];
            const parts = noQuery.split("/");
            const file = parts[parts.length - 1] || "track";
            const withoutExt = file.includes(".") ? file.substring(0, file.lastIndexOf(".")) : file;
            return decodeURIComponent(withoutExt).trim() || "track";
        } catch {
            return "track";
        }
    };

    const addUrlToPlaylist = async (deck: string, url: string) => {
        const youtubeAudioUrl = await requestYoutubeAudio(url) as string;
        console.log("RES", youtubeAudioUrl);
        const item: PlaylistItem = {
            id: `${Date.now()}_${Math.random().toString(36).slice(2)}`,
            title: deriveTitleFromUrlOrName(youtubeAudioUrl),
            src: youtubeAudioUrl,
            sourceType: "url",
            baseBpm: null,
        };
        setDecks(prev => {
            const list = prev[deck]?.playlist || [];
            return { ...prev, [deck]: { ...prev[deck], playlist: [...list, item] } };
        });
        const bpm = await analyzeBpmForUrl(youtubeAudioUrl);
        if (bpm) {
            setDecks(prev => {
                const list = prev[deck]?.playlist || [];
                const idx = list.findIndex(it => it.id === item.id);
                if (idx === -1) return prev;
                const next = [...list];
                next[idx] = { ...next[idx], baseBpm: bpm };
                return { ...prev, [deck]: { ...prev[deck], playlist: next } };
            });
        }
    };

    const addFileToPlaylist = async (deck: string, file: File) => {
        const url = URL.createObjectURL(file);
        const item: PlaylistItem = {
            id: `${Date.now()}_${Math.random().toString(36).slice(2)}`,
            title: deriveTitleFromUrlOrName(file.name),
            src: url,
            sourceType: "file",
            baseBpm: null,
        };
        setDecks(prev => {
            const list = prev[deck]?.playlist || [];
            return { ...prev, [deck]: { ...prev[deck], playlist: [...list, item] } };
        });
        const bpm = await analyzeBpmFromBlob(file);
        if (bpm) {
            setDecks(prev => {
                const list = prev[deck]?.playlist || [];
                const idx = list.findIndex(it => it.id === item.id);
                if (idx === -1) return prev;
                const next = [...list];
                next[idx] = { ...next[idx], baseBpm: bpm };
                return { ...prev, [deck]: { ...prev[deck], playlist: next } };
            });
        }
    };

    const loadPlaylistItem = async (deck: string, itemId: string) => {
        const d = decks[deck];
        if (!d?.audio) return;
        const item = d.playlist?.find(x => x.id === itemId);
        if (!item) return;
        const wasPlaying = d.isPlaying;
        if (d.objectUrl && d.objectUrl !== item.src) {
            try { URL.revokeObjectURL(d.objectUrl); } catch {}
        }
        d.audio.pause();
        d.audio.src = item.src;
        d.audio.currentTime = 0;
        d.audio.loop = true;
        d.audio.preload = "auto";
        try {
            (d.audio as any).preservesPitch = false;
            (d.audio as any).mozPreservesPitch = false;
            (d.audio as any).webkitPreservesPitch = false;
        } catch {}
        d.audio.load();
        setDecks(prev => ({
            ...prev,
            [deck]: {
                ...prev[deck],
                baseBpm: item.baseBpm ?? null,
                currentTime: 0,
                duration: 0,
                isPlaying: false,
                objectUrl: item.sourceType === "file" ? item.src : undefined,
                currentItemId: item.id,
            }
        }));
        const resumeIfNeeded = async () => {
            if (wasPlaying) {
                try { await audioCtxRef.current?.resume?.(); } catch {}
                try {
                    await d.audio.play();
                    setDecks(prev => ({ ...prev, [deck]: { ...prev[deck], isPlaying: true } }));
                } catch {}
            }
        };
        d.audio.addEventListener("canplay", resumeIfNeeded, { once: true });
        if (item.baseBpm == null) {
            const bpm = item.sourceType === "url"
                ? await analyzeBpmForUrl(item.src)
                : await (async () => {
                    try { const res = await fetch(item.src); const b = await res.blob(); return await analyzeBpmFromBlob(b); } catch { return null; }
                })();
            if (bpm) {
                setDecks(prev => {
                    const list = prev[deck]?.playlist || [];
                    const idx = list.findIndex(it => it.id === itemId);
                    const nextList = [...list];
                    if (idx !== -1) nextList[idx] = { ...nextList[idx], baseBpm: bpm };
                    const isCurrent = prev[deck]?.currentItemId === itemId;
                    return {
                        ...prev,
                        [deck]: { ...prev[deck], playlist: nextList, baseBpm: isCurrent ? bpm : prev[deck].baseBpm }
                    };
                });
            }
        }
    };

    const removePlaylistItem = (deck: string, itemId: string) => {
        const d = decks[deck];
        if (!d) return;
        const item = d.playlist?.find(x => x.id === itemId);
        if (item?.sourceType === "file" && item.src !== d.audio.src) {
            try { URL.revokeObjectURL(item.src); } catch {}
        }
        setDecks(prev => {
            const list = prev[deck]?.playlist || [];
            const next = list.filter(it => it.id !== itemId);
            const wasCurrent = prev[deck]?.currentItemId === itemId;
            return { ...prev, [deck]: { ...prev[deck], playlist: next, currentItemId: wasCurrent ? null : prev[deck].currentItemId } };
        });
    };

    const [isAddDialogOpen, setIsAddDialogOpen] = useState(false);
    const [addDialogDeck, setAddDialogDeck] = useState<"track_1" | "track_2">("track_1");
    const [addDialogUrl, setAddDialogUrl] = useState("");

    // Estimate BPM via simple onset-envelope autocorrelation (downsampled to ~200 Hz)
    function estimateBpmFromBuffer(buffer: AudioBuffer): number | null {
        const duration = Math.min(buffer.duration, 30); // analyze up to 30s
        const sampleRate = buffer.sampleRate;
        const totalSamples = Math.min(Math.floor(duration * sampleRate), buffer.length);

        // Mixdown to mono (lightweight)
        const tmp = new Float32Array(totalSamples);
        const numChannels = buffer.numberOfChannels;
        for (let ch = 0; ch < numChannels; ch++) {
            const chData = buffer.getChannelData(ch);
            for (let i = 0; i < totalSamples; i++) {
                tmp[i] += chData[i];
            }
        }
        if (numChannels > 0) {
            for (let i = 0; i < totalSamples; i++) tmp[i] /= numChannels;
        }

        // Build simple onset envelope at ~200 Hz by sampling abs signal
        const envRate = 200; // Hz
        const step = sampleRate / envRate;
        const envLength = Math.max(1, Math.floor(totalSamples / step));
        const envelope = new Float32Array(envLength);
        for (let k = 0; k < envLength; k++) {
            const idx = Math.min(totalSamples - 1, Math.floor(k * step));
            envelope[k] = Math.abs(tmp[idx]);
        }

        // Smooth envelope with small moving average (~20 ms at 200 Hz ≈ 4 samples)
        const smooth = new Float32Array(envLength);
        const win = 4;
        let acc = 0;
        for (let i = 0; i < envLength; i++) {
            acc += envelope[i];
            if (i >= win) acc -= envelope[i - win];
            smooth[i] = acc / Math.min(i + 1, win);
        }

        // Normalize and mean-center
        let mean = 0;
        for (let i = 0; i < envLength; i++) mean += smooth[i];
        mean /= envLength || 1;
        for (let i = 0; i < envLength; i++) smooth[i] -= mean;

        // Autocorrelation over plausible BPS range [1, 3] => lags [envRate/3, envRate/1]
        const minLag = Math.max(1, Math.floor(envRate / 3)); // fastest: 3 bps
        const maxLag = Math.min(envLength - 1, Math.floor(envRate / 1)); // slowest: 1 bps
        if (maxLag <= minLag + 2) return null;

        let bestLag = -1;
        let bestVal = -Infinity;
        // Precompute energy for normalization (optional simple)
        for (let lag = minLag; lag <= maxLag; lag++) {
            let sum = 0;
            const limit = envLength - lag;
            for (let i = 0; i < limit; i++) {
                sum += smooth[i] * smooth[i + lag];
            }
            if (sum > bestVal) {
                bestVal = sum;
                bestLag = lag;
            }
        }
        if (bestLag <= 0) return null;

        const bps = envRate / bestLag;
        let bpm = bps * 60;

        // Fold to typical DJ ranges (60–180 BPM) heuristically
        while (bpm < 60) bpm *= 2;
        while (bpm > 180) bpm /= 2;

        if (!isFinite(bpm) || bpm <= 0) return null;
        return bpm;
    }

    const toggleDeck = async (deck: string) => {
        const d = decks[deck];
        if (!d?.audio) return;
        const ctx = audioCtxRef.current;
        if (d.isPlaying) {
            d.audio.pause();
            setDecks(prev => ({ ...prev, [deck]: { ...prev[deck], isPlaying: false } }));
        } else {
            try { await ctx?.resume?.(); } catch {}
            try {
                await d.audio.play();
                setDecks(prev => ({ ...prev, [deck]: { ...prev[deck], isPlaying: true } }));
            } catch {
                // autoplay blocked or play failed; keep state unchanged
            }
        }
    };

    // onUploadFile removed; we use addFileToPlaylist in the dialog

    const formatTime = (secs?: number) => {
        const s = Math.max(0, Math.floor(secs || 0));
        const m = Math.floor(s / 60);
        const r = s % 60;
        return `${m}:${r.toString().padStart(2, "0")}`;
    };

    return (decks.track_1 && decks.track_2) ? (
        <div className="bg-background" style={{ display: "flex", flexDirection: "column", gap: 16 }}>
            {/* Local styles for vinyl visuals and controls */}
            <style>
                {`
                @keyframes spin {
                    0% { transform: rotate(0deg); }
                    100% { transform: rotate(360deg); }
                }
                .deck {
                    display: flex;
                    flex-direction: column;
                    align-items: center;
                    gap: 8px;
                    flex: 1;
                    min-width: 0;
                }
                .vinyl {
                    width: 180px;
                    height: 180px;
                    border-radius: 50%;
                    background: radial-gradient(circle at 50% 50%, #333 0%, #111 40%, #000 70%);
                    box-shadow: inset 0 0 0 3px #222, inset 0 0 0 6px #111;
                    position: relative;
                    cursor: pointer;
                    transition: transform 120ms ease, box-shadow 200ms ease;
                }
                .vinyl::after {
                    content: "";
                    position: absolute;
                    top: 50%;
                    left: 50%;
                    transform: translate(-50%, -50%);
                    width: 48px;
                    height: 48px;
                    border-radius: 50%;
                    background: #e23d3d; /* label */
                    box-shadow: inset 0 0 0 4px rgba(0,0,0,0.25);
                }
                .spinning {
                    animation: spin 3.5s linear infinite;
                }
                /* Wobble effect */
                @keyframes wobble {
                    0% { transform: translate(-50%, -50%) scaleX(1.000) scaleY(1.000); }
                    50% { transform: translate(-50%, -50%) scaleX(0.992) scaleY(1.008); }
                    100% { transform: translate(-50%, -50%) scaleX(1.000) scaleY(1.000); }
                }
                .wobbleMask {
                    position: absolute;
                    top: 50%;
                    left: 50%;
                    width: 100%;
                    height: 100%;
                    border-radius: 50%;
                    pointer-events: none;
                    /* Subtle moving highlight that becomes perceptible with wobble */
                    background: radial-gradient(ellipse at 62% 38%, rgba(255,255,255,0.06) 0%, rgba(255,255,255,0.0) 35%),
                                radial-gradient(ellipse at 30% 70%, rgba(255,255,255,0.035) 0%, rgba(255,255,255,0.0) 35%);
                    transform: translate(-50%, -50%);
                    animation: wobble 1200ms ease-in-out infinite;
                }
                .vinyl:hover {
                    box-shadow: inset 0 0 0 3px #222, inset 0 0 0 6px #111, 0 8px 20px rgba(0,0,0,0.35);
                }
                .vinyl:active {
                    transform: scale(0.98);
                }
                .vinylOverlay {
                    position: absolute;
                    top: 50%;
                    left: 50%;
                    width: 64px;
                    height: 64px;
                    transform: translate(-50%, -50%) scale(0.92);
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    border-radius: 50%;
                    background: rgba(0,0,0,0.45);
                    box-shadow: 0 6px 18px rgba(0,0,0,0.35), inset 0 0 0 1px rgba(255,255,255,0.08);
                    backdrop-filter: blur(2px);
                    color: white;
                    opacity: 0.85;
                    transition: opacity 140ms ease, transform 140ms ease, background 200ms ease;
                    pointer-events: none;
                }
                .vinyl:hover .vinylOverlay {
                    opacity: 1;
                    transform: translate(-50%, -50%) scale(1);
                    background: rgba(0,0,0,0.55);
                }
                @keyframes pulseGlow {
                    0% { box-shadow: 0 0 0 rgba(226,61,61,0.0), inset 0 0 0 1px rgba(255,255,255,0.08); }
                    50% { box-shadow: 0 0 28px rgba(226,61,61,0.35), inset 0 0 0 1px rgba(255,255,255,0.1); }
                    100% { box-shadow: 0 0 0 rgba(226,61,61,0.0), inset 0 0 0 1px rgba(255,255,255,0.08); }
                }
                .playing .vinylOverlay {
                    animation: pulseGlow 1600ms ease-in-out infinite;
                }
                .controls {
                    display: flex;
                    gap: 8px;
                    align-items: center;
                }
                .resetBtn {
                    margin-left: 8px;
                    padding: 2px 6px;
                    border: 1px solid #555;
                    border-radius: 4px;
                    background: #1e1e1e;
                    color: #ddd;
                    cursor: pointer;
                    transition: background 120ms ease, transform 80ms ease;
                }
                .resetBtn:hover {
                    background: #262626;
                }
                .resetBtn:active {
                    transform: translateY(1px);
                }
                .mixerRow {
                    display: flex;
                    align-items: center;
                    gap: 12px;
                }
                .range {
                    width: 280px;
                }
                .deckRow {
                    display: flex;
                    gap: 16px;
                    width: 100%;
                    align-items: flex-start;
                }
                .playlistCol {
                    width: 300px;
                    max-width: 320px;
                    display: flex;
                    flex-direction: column;
                    gap: 8px;
                }
                .controlsCol {
                    flex: 1;
                    display: flex;
                    flex-direction: column;
                    gap: 8px;
                    align-items: center;
                }
                /* Vertical slider helpers */
                .vGroup {
                    display: flex;
                    flex-direction: column;
                    align-items: center;
                    gap: 6px;
                    height: 220px;
                }
                .vRange {
                    -webkit-appearance: slider-vertical; /* Chrome/Edge/Safari */
                    appearance: auto;
                    writing-mode: bt-lr; /* Firefox */
                    width: 100%; /* thickness; keep in sync with thumb width for look */
                    height: 12px; /* fill the group */
                    transform: rotate(90deg);
                    flex: 1; /* take remaining vertical space between label and bottom info */
                }
                .vRange.vOpposite {
                    transform: rotate(-90deg);
                }
                /* Custom range styling with image thumb */
                .range {
                    -webkit-appearance: none;
                    appearance: none;
                    background: transparent;
                    outline: none;
                }
                /* WebKit track */
                .range::-webkit-slider-runnable-track {
                    height: 6px;
                    background: linear-gradient(180deg, #2a2a2a, #1a1a1a);
                    border-radius: 999px;
                    box-shadow: inset 0 0 0 1px rgba(255,255,255,0.06), 0 1px 2px rgba(0,0,0,0.4);
                }
                /* Firefox track */
                .range::-moz-range-track {
                    height: 6px;
                    background: linear-gradient(180deg, #2a2a2a, #1a1a1a);
                    border-radius: 999px;
                    box-shadow: inset 0 0 0 1px rgba(255,255,255,0.06), 0 1px 2px rgba(0,0,0,0.4);
                }
                /* IE/Edge (legacy) track */
                .range::-ms-track {
                    height: 6px;
                    background: transparent;
                    border-color: transparent;
                    color: transparent;
                }
                .range::-ms-fill-lower,
                .range::-ms-fill-upper {
                    background: linear-gradient(180deg, #2a2a2a, #1a1a1a);
                    border-radius: 999px;
                    box-shadow: inset 0 0 0 1px rgba(255,255,255,0.06), 0 1px 2px rgba(0,0,0,0.4);
                }
                /* WebKit thumb */
                .range::-webkit-slider-thumb {
                    -webkit-appearance: none;
                    appearance: none;
                    width: 12px;
                    height: 28px;
                    border: none;
                    background: url('/nui/images/slider.png') no-repeat center center / contain;
                    cursor: pointer;
                    margin-top: -11px; /* centers thumb on 6px track */
                    box-shadow: 0 2px 6px rgba(0,0,0,0.5);
                }
                /* Firefox thumb */
                .range::-moz-range-thumb {
                    width: 28px;
                    height: 28px;
                    border: none;
                    border-radius: 4px;
                    background: url('/nui/images/slider.png') no-repeat center center / contain;
                    cursor: pointer;
                    box-shadow: 0 2px 6px rgba(0,0,0,0.5);
                }
                /* IE/Edge (legacy) thumb */
                .range::-ms-thumb {
                    width: 28px;
                    height: 28px;
                    border: none;
                    border-radius: 4px;
                    background: url('/nui/images/slider.png') no-repeat center center / contain;
                    cursor: pointer;
                    box-shadow: 0 2px 6px rgba(0,0,0,0.5);
                }
                /* Focus styles */
                .range:focus-visible {
                    outline: none;
                }
                .range:focus::-webkit-slider-runnable-track {
                    box-shadow: inset 0 0 0 1px rgba(255,255,255,0.12), 0 0 0 2px rgba(226,61,61,0.25);
                }
                .range:focus::-moz-range-track {
                    box-shadow: inset 0 0 0 1px rgba(255,255,255,0.12), 0 0 0 2px rgba(226,61,61,0.25);
                }
                /* Modal */
                .modalBackdrop {
                    position: fixed;
                    inset: 0;
                    background: rgba(0,0,0,0.55);
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    z-index: 9999;
                }
                .modal {
                    width: 520px;
                    max-width: calc(100vw - 32px);
                    background: #0f0f0f;
                    color: #eee;
                    border: 1px solid #333;
                    border-radius: 10px;
                    box-shadow: 0 20px 60px rgba(0,0,0,0.6);
                    padding: 16px;
                }
                .modalHeader {
                    display: flex;
                    align-items: center;
                    justify-content: space-between;
                    margin-bottom: 12px;
                }
                .modalBody {
                    display: flex;
                    flex-direction: column;
                    gap: 12px;
                }
                .modalActions {
                    display: flex;
                    justify-content: flex-end;
                    gap: 8px;
                    margin-top: 8px;
                }
                .fieldRow {
                    display: flex;
                    gap: 8px;
                    align-items: center;
                }
                .radioRow {
                    display: flex;
                    gap: 16px;
                    align-items: center;
                }
                .divider {
                    height: 1px;
                    background: #222;
                    margin: 6px 0;
                    border: none;
                }
                `}
            </style>
            <div style={{ display: "flex", gap: 16 }}>
                {Object.keys({track_1: decks.track_1, controls: decks.controls, track_2: decks.track_2}).map(function(deck) {
                    if (deck === "controls") {
                        return (
                            <div style={{ display: "flex", flexDirection: "column", gap: 8, alignItems: "center" }}>
                            <div className="mixerRow" style={{ gap: 24, justifyContent: "center" }}>
                                <div className="vGroup">
                                    <span>Left</span>
                                    <input
                                        className="range vRange"
                                        type="range"
                                        min={0}
                                        max={100}
                                        step={1}
                                        value={Math.round(crossfade * 100)}
                                        onChange={(e) => setCrossfade(Number(e.target.value) / 100)}
                                        aria-label="Crossfader"
                                    />
                                    <span>Right</span>
                                    <button
                                        className="resetBtn"
                                        onClick={() => setCrossfade(0.5)}
                                        aria-label="Reset crossfader"
                                        title="Reset crossfader"
                                    >
                                        ↺
                                    </button>
                                </div>
                                <div className="vGroup">
                                    <span>Master</span>
                                    <input
                                        className="range vRange vOpposite"
                                        type="range"
                                        min={0}
                                        max={100}
                                        step={1}
                                        value={Math.round(masterVolume * 100)}
                                        onChange={(e) => setMasterVolume(Number(e.target.value) / 100)}
                                        aria-label="Master volume"
                                    />
                                    <span>{Math.round(masterVolume * 100)}%</span>
                                    <button
                                        className="resetBtn"
                                        onClick={() => setMasterVolume(0.6)}
                                        aria-label="Reset master volume"
                                        title="Reset master volume"
                                    >
                                        ↺
                                    </button>
                                </div>
                            </div>
                            <div className="mixerRow" style={{ gap: 12, justifyContent: "center" }}>
                                <button
                                    className="resetBtn"
                                    onClick={() => { setIsAddDialogOpen(true); }}
                                    aria-label="Add Song to Playlist"
                                    title="Add Song to Playlist"
                                >
                                    Add Song to Playlist
                                </button>
                            </div>
                            <div className="mixerRow" style={{ gap: 24, justifyContent: "center" }}>
                                {Object.keys(decks).map(function(deck) {
                                    return (
                                        <div className="playlistCol">
                                            <div style={{ display: "flex", flexDirection: "column", gap: 6, width: "100%", alignItems: "stretch" }}>
                                                {(decks[deck].playlist ?? []).map(item => (
                                                    <div key={item.id} style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 8, width: "100%" }}>
                                                        <div style={{ display: "flex", alignItems: "center", gap: 8, minWidth: 0 }}>
                                                            <div style={{ width: 6, height: 6, borderRadius: 999, background: decks[deck].currentItemId === item.id ? "#60d394" : "#555" }} />
                                                            <div style={{ whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", maxWidth: 220 }}>{item.title}</div>
                                                            {typeof item.baseBpm === "number" ? (
                                                                <span style={{ opacity: 0.7, fontSize: 12 }}>• {item.baseBpm.toFixed(0)} BPM</span>
                                                            ) : (
                                                                <span style={{ opacity: 0.5, fontSize: 12 }}>• analyzing…</span>
                                                            )}
                                                        </div>
                                                        <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
                                                            <button
                                                                className="resetBtn"
                                                                onClick={() => loadPlaylistItem(deck, item.id)}
                                                                title="Load"
                                                            >
                                                                Load
                                                            </button>
                                                            <button
                                                                className="resetBtn"
                                                                onClick={() => removePlaylistItem(deck, item.id)}
                                                                title="Remove"
                                                            >
                                                                ✕
                                                            </button>
                                                        </div>
                                                    </div>
                                                ))}
                                            </div>
                                        </div>
                                    );
                                })}
                            </div>
                        </div>
                        )
                    } else {
                        return (
                            <div className="deck" key={deck}>
                                <div className="deckRow">
                                    <div className="controlsCol">
                                        <div
                                            className={`vinyl ${decks[deck].isPlaying ? "spinning playing" : ""}`}
                                            onClick={() => toggleDeck(deck)}
                                            onKeyDown={(e) => {
                                                if (e.key === "Enter" || e.key === " ") {
                                                    e.preventDefault();
                                                    toggleDeck(deck);
                                                }
                                            }}
                                            role="button"
                                            aria-label={decks[deck].isPlaying ? "Pause deck" : "Play deck"}
                                            tabIndex={0}
                                        >
                                            <div className="wobbleMask" />
                                            <div className="vinylOverlay" style={{ zIndex: 10 }}>
                                                {decks[deck].isPlaying ? (
                                                    <svg width="28" height="28" viewBox="0 0 24 24" aria-hidden="true">
                                                        <rect x="5" y="4" width="5" height="16" rx="1" fill="currentColor"></rect>
                                                        <rect x="14" y="4" width="5" height="16" rx="1" fill="currentColor"></rect>
                                                    </svg>
                                                ) : (
                                                    <svg width="28" height="28" viewBox="0 0 24 24" aria-hidden="true">
                                                        <path d="M8 5v14l11-7z" fill="currentColor"></path>
                                                    </svg>
                                                )}
                                            </div>
                                        </div>
                                        <div className="controls">
                                            <span>BPM:</span>
                                            <strong>
                                                {decks[deck].baseBpm
                                                    ? (decks[deck].baseBpm * decks[deck].tempo).toFixed(2)
                                                    : "—"}
                                            </strong>
                                            {decks[deck].baseBpm ? (
                                                <span style={{ opacity: 0.7 }}> (base {decks[deck].baseBpm.toFixed(2)})</span>
                                            ) : null}
                                        </div>
                                        <div className="controls" style={{ width: "100%", justifyContent: "center" }}>
                                            <span>{formatTime(decks[deck].currentTime)}</span>
                                            <input
                                                className="range"
                                                type="range"
                                                min={0}
                                                max={Math.max(0, decks[deck].duration || 0)}
                                                step={0.01}
                                                value={Math.min(decks[deck].currentTime || 0, decks[deck].duration || 0)}
                                                onChange={(e) => {
                                                    const to = Number(e.target.value);
                                                    decks[deck].audio.currentTime = to;
                                                    setDecks(prev => ({ ...prev, [deck]: { ...prev[deck], currentTime: to } }));
                                                }}
                                                aria-label={`${deck} position`}
                                                disabled={!decks[deck].duration || decks[deck].duration === 0}
                                            />
                                            <span>{formatTime(decks[deck].duration)}</span>
                                        </div>
                                        <div className="controls" style={{ width: "100%", justifyContent: "center", gap: 24 }}>
                                            <div className="vGroup">
                                                <span>Tempo</span>
                                                <input
                                                    className="range vRange"
                                                    type="range"
                                                    min={50}
                                                    max={150}
                                                    step={1}
                                                    value={Math.round(decks[deck].tempo * 100)}
                                                    onChange={(e) => { 
                                                        setDecks(prev => ({ ...prev, [deck]: { ...prev[deck], tempo: Number(e.target.value) / 100 } }));
                                                    }}
                                                    aria-label={`${deck} tempo`}
                                                />
                                                <span>{Math.round(decks[deck].tempo * 100)}%</span>
                                                <button
                                                    className="resetBtn"
                                                    onClick={() => setDecks(prev => ({ ...prev, [deck]: { ...prev[deck], tempo: 1 } }))}
                                                    aria-label={`${deck} reset tempo`}
                                                    title="Reset tempo"
                                                >
                                                    ↺
                                                </button>
                                            </div>
                                            <div className="vGroup">
                                                <span>Volume</span>
                                                <input
                                                    className="range vRange"
                                                    type="range"
                                                    min={0}
                                                    max={100}
                                                    step={1}
                                                    value={Math.round((decks[deck].deckVolume ?? 1) * 100)}
                                                    onChange={(e) => {
                                                        const v = Number(e.target.value) / 100;
                                                        setDecks(prev => ({ ...prev, [deck]: { ...prev[deck], deckVolume: v } }));
                                                    }}
                                                    aria-label={`${deck} volume`}
                                                />
                                                <span>{Math.round((decks[deck].deckVolume ?? 1) * 100)}%</span>
                                                <button
                                                    className="resetBtn"
                                                    onClick={() => setDecks(prev => ({ ...prev, [deck]: { ...prev[deck], deckVolume: 1 } }))}
                                                    aria-label={`${deck} reset volume`}
                                                    title="Reset volume"
                                                >
                                                    ↺
                                                </button>
                                            </div>
                                        </div>
                                        <div className="controls">
                                            <label style={{ display: "flex", alignItems: "center", gap: 4 }}>
                                                <input
                                                    type="checkbox"
                                                    checked={monitorDeck === deck}
                                                    onChange={(e) => {
                                                        if (e.target.checked) {
                                                            setMonitorDeck(deck);
                                                            audioCtxRef.current?.resume?.();
                                                        } else if (monitorDeck === deck) {
                                                            setMonitorDeck(null);
                                                        }
                                                    }}
                                                />
                                                <span>Monitor</span>
                                            </label>
                                        </div>
                                    </div>
                                </div>
                            </div>
                        );
                    }
                })}
            </div>
            {isAddDialogOpen && (
                <div className="modalBackdrop" role="dialog" aria-modal="true" aria-labelledby="add-song-title">
                    <div className="modal">
                        <div className="modalHeader">
                            <h3 id="add-song-title" style={{ margin: 0, fontSize: 16 }}>Add Song to Playlist</h3>
                            <button className="resetBtn" onClick={() => setIsAddDialogOpen(false)} aria-label="Close add song dialog">✕</button>
                        </div>
                        <div className="modalBody">
                            <div className="radioRow" role="group" aria-label="Choose target deck">
                                <label style={{ display: "flex", alignItems: "center", gap: 6 }}>
                                    <input
                                        type="radio"
                                        name="deckPick"
                                        checked={addDialogDeck === "track_1"}
                                        onChange={() => setAddDialogDeck("track_1")}
                                    />
                                    <span>Left Deck</span>
                                </label>
                                <label style={{ display: "flex", alignItems: "center", gap: 6 }}>
                                    <input
                                        type="radio"
                                        name="deckPick"
                                        checked={addDialogDeck === "track_2"}
                                        onChange={() => setAddDialogDeck("track_2")}
                                    />
                                    <span>Right Deck</span>
                                </label>
                            </div>
                            <hr className="divider" />
                            <div>
                                <div style={{ marginBottom: 4, opacity: 0.8 }}>From URL</div>
                                <div className="fieldRow">
                                    <input
                                        type="text"
                                        placeholder="https://example.com/track.mp3"
                                        value={addDialogUrl}
                                        onChange={(e) => setAddDialogUrl(e.target.value)}
                                        style={{ flex: 1, padding: "6px 8px", borderRadius: 6, border: "1px solid #333", background: "#0c0c0c", color: "#eee" }}
                                        aria-label="Song URL"
                                    />
                                    <button
                                        className="resetBtn"
                                        onClick={async () => {
                                            const url = addDialogUrl.trim();
                                            if (!url) return;
                                            await addUrlToPlaylist(addDialogDeck, url);
                                            setAddDialogUrl("");
                                            setIsAddDialogOpen(false);
                                        }}
                                        disabled={!addDialogUrl.trim()}
                                        aria-label="Add URL to playlist"
                                    >
                                        Add URL
                                    </button>
                                </div>
                            </div>
                            <div>
                                <div style={{ marginBottom: 4, opacity: 0.8 }}>Upload File</div>
                                <label className="resetBtn" style={{ display: "inline-flex", alignItems: "center", gap: 6, cursor: "pointer" }}>
                                    <input
                                        type="file"
                                        accept="audio/*"
                                        style={{ display: "none" }}
                                        onChange={async (e) => {
                                            const file = e.target.files?.[0];
                                            if (file) {
                                                await addFileToPlaylist(addDialogDeck, file);
                                                setIsAddDialogOpen(false);
                                            }
                                            if (e.currentTarget) e.currentTarget.value = "";
                                        }}
                                    />
                                    <span>Choose File…</span>
                                </label>
                            </div>
                        </div>
                        <div className="modalActions">
                            <button className="resetBtn" onClick={() => setIsAddDialogOpen(false)}>Close</button>
                        </div>
                    </div>
                </div>
            )}
        </div>
    ) : null;
}