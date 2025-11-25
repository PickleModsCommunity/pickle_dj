import { useEffect, useRef, useState } from "react";

type Deck = {
    audio: HTMLAudioElement;
    isPlaying: boolean;
    tempo: number;
    baseBpm: number | null;
    currentTime?: number;
    duration?: number;
}

export default function Music() {
    const [decks, setDecks] = useState<Record<string, Deck>>({});
    const [crossfade, setCrossfade] = useState(0.5); // 0 = left only, 1 = right only
    const [masterVolume, setMasterVolume] = useState(0.6); // overall gain cap

    // Web Audio routing
    const audioCtxRef = useRef<AudioContext | null>(null);
    const nodesRef = useRef<Record<string, { source: MediaElementAudioSourceNode; gain: GainNode; panner: StereoPannerNode }>>({});

    // Monitor state: only one side at a time; route selected deck to that side
    const [monitor, setMonitor] = useState<{ deck: string | null; side: "L" | "R" | null }>({
        deck: null,
        side: null,
    });

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
        setDecks({
            track_1: {
                audio: t1,
                isPlaying: false,
                tempo: 1,
                baseBpm: null,
                currentTime: 0,
                duration: 0,
            },
            track_2: {
                audio: t2,
                isPlaying: false,
                tempo: 1,
                baseBpm: null,
                currentTime: 0,
                duration: 0,
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
        const theta = crossfade * 0.5 * Math.PI;
        const leftGain = Math.cos(theta);
        const rightGain = Math.sin(theta);
        const n1 = nodesRef.current["track_1"];
        const n2 = nodesRef.current["track_2"];
        if (n1) n1.gain.gain.value = Math.max(0, Math.min(1, leftGain * masterVolume));
        if (n2) n2.gain.gain.value = Math.max(0, Math.min(1, rightGain * masterVolume));
        decks.track_1.audio.playbackRate = decks.track_1.tempo;
        decks.track_2.audio.playbackRate = decks.track_2.tempo;
    }, [decks, crossfade, masterVolume]);

    // Apply monitor routing via stereo panners
    useEffect(() => {
        const n1 = nodesRef.current["track_1"];
        const n2 = nodesRef.current["track_2"];
        if (!n1 || !n2) return;
        if (!monitor.deck || !monitor.side) {
            n1.panner.pan.value = 0;
            n2.panner.pan.value = 0;
            return;
        }
        const isLeft = monitor.side === "L";
        const monitored = monitor.deck === "track_1" ? n1 : n2;
        const other = monitor.deck === "track_1" ? n2 : n1;
        monitored.panner.pan.value = isLeft ? -1 : 1; // hard left or right
        other.panner.pan.value = isLeft ? 1 : -1;     // opposite ear
    }, [monitor]);

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

    const formatTime = (secs?: number) => {
        const s = Math.max(0, Math.floor(secs || 0));
        const m = Math.floor(s / 60);
        const r = s % 60;
        return `${m}:${r.toString().padStart(2, "0")}`;
    };

    return (decks.track_1 && decks.track_2) ? (
        <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
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
                .controls {
                    display: flex;
                    gap: 8px;
                    align-items: center;
                }
                .mixerRow {
                    display: flex;
                    align-items: center;
                    gap: 12px;
                }
                .range {
                    width: 280px;
                }
                `}
            </style>
            <input type="file"/>
            <div style={{ display: "flex", gap: 16 }}>
                {Object.keys(decks).map((deck) => (
                    <div className="deck" key={deck}>
                        <div className={`vinyl ${decks[deck].isPlaying ? "spinning" : ""}`} />
                        <div className="controls">
                            <button onClick={() => toggleDeck(deck)}>{decks[deck].isPlaying ? "Pause" : "Play"}</button>
                            <span>{deck.replace("track_", "")}</span>
                        </div>
                        <div className="controls">
                            <span>BPS:</span>
                            <strong>
                                {decks[deck].baseBpm
                                    ? (decks[deck].baseBpm / 60 * decks[deck].tempo).toFixed(2)
                                    : "—"}
                            </strong>
                            {decks[deck].baseBpm ? (
                                <span style={{ opacity: 0.7 }}> (base {(decks[deck].baseBpm / 60).toFixed(2)})</span>
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
                        <div className="controls" style={{ width: "100%", justifyContent: "center" }}>
                            <span>Tempo</span>
                            <input
                                className="range"
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
                        </div>
                     <div className="controls">
                         <label style={{ display: "flex", alignItems: "center", gap: 4 }}>
                             <input
                                 type="checkbox"
                                 checked={monitor.deck === deck && monitor.side === "L"}
                                 onChange={(e) => {
                                     if (e.target.checked) {
                                         setMonitor({ deck, side: "L" });
                                         audioCtxRef.current?.resume?.();
                                     } else {
                                         if (monitor.deck === deck && monitor.side === "L") {
                                             setMonitor({ deck: null, side: null });
                                         }
                                     }
                                 }}
                             />
                             <span>Monitor L</span>
                         </label>
                         <label style={{ display: "flex", alignItems: "center", gap: 4 }}>
                             <input
                                 type="checkbox"
                                 checked={monitor.deck === deck && monitor.side === "R"}
                                 onChange={(e) => {
                                     if (e.target.checked) {
                                         setMonitor({ deck, side: "R" });
                                         audioCtxRef.current?.resume?.();
                                     } else {
                                         if (monitor.deck === deck && monitor.side === "R") {
                                             setMonitor({ deck: null, side: null });
                                         }
                                     }
                                 }}
                             />
                             <span>Monitor R</span>
                         </label>
                     </div>
                    </div>
                ))}
            </div>
            <div style={{ display: "flex", flexDirection: "column", gap: 8, alignItems: "center" }}>
                <div className="mixerRow">
                    <span>Left</span>
                    <input
                        className="range"
                        type="range"
                        min={0}
                        max={100}
                        step={1}
                        value={Math.round(crossfade * 100)}
                        onChange={(e) => setCrossfade(Number(e.target.value) / 100)}
                        aria-label="Crossfader"
                    />
                    <span>Right</span>
                </div>
                <div className="mixerRow">
                    <span>Master</span>
                    <input
                        className="range"
                        type="range"
                        min={0}
                        max={100}
                        step={1}
                        value={Math.round(masterVolume * 100)}
                        onChange={(e) => setMasterVolume(Number(e.target.value) / 100)}
                        aria-label="Master volume"
                    />
                    <span>{Math.round(masterVolume * 100)}%</span>
                </div>
            </div>
        </div>
    ) : null;
}