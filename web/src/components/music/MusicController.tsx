import { useEffect, useRef, useState } from "react";
import { useNuiEvent } from "../../providers/nui/useNui";
import RangeControl, { VuMeter } from "./RangeControl";
import { Mic, MicOff, Plus } from "lucide-react";
import { fetchNui } from "@/providers/nui/fetchNui";
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
    sourceType: "url" | "file" | "youtube";
    baseBpm?: number | null;
};

export default function MusicController() {
    const [decks, setDecks] = useState<Record<string, Deck>>({});
    const decksRef = useRef<Record<string, Deck>>({});
    const [crossfade, setCrossfade] = useState(0.5); // 0 = left only, 1 = right only
    const [masterVolume, setMasterVolume] = useState(1); // overall gain cap

    useEffect(() => {
        console.log("MusicController: mounted");
        return () => console.log("MusicController: unmounted");
    }, []);
    // Web Audio routing
    const audioCtxRef = useRef<AudioContext | null>(null);
    const nodesRef = useRef<Record<string, { source: MediaElementAudioSourceNode; gain: GainNode; panner: StereoPannerNode; analyser?: AnalyserNode; altSource?: MediaElementAudioSourceNode }>>({});
    const masterBusRef = useRef<GainNode | null>(null);
    const broadcastBusRef = useRef<GainNode | null>(null);
    const streamDestRef = useRef<MediaStreamAudioDestinationNode | null>(null);
    const masterAnalyserRef = useRef<AnalyserNode | null>(null);
    const monitorConnectedRef = useRef<boolean>(true);
	const micAnalyserRef = useRef<AnalyserNode | null>(null);
    const [isBroadcasting, setIsBroadcasting] = useState(false);
    // Mic capture/mix
    const micStreamRef = useRef<MediaStream | null>(null);
    const micSourceRef = useRef<MediaStreamAudioSourceNode | null>(null);
    const micGainRef = useRef<GainNode | null>(null);
    const [isMicOn, setIsMicOn] = useState(false);
    const [micDevices, setMicDevices] = useState<MediaDeviceInfo[]>([]);
    const [selectedMicId, setSelectedMicId] = useState<string | "default" | null>(null);

    const peerMapRef = useRef<Record<number, RTCPeerConnection>>({});
    const outboundTrackRef = useRef<MediaStreamTrack | null>(null);
    const streamIdRef = useRef<string | null>(null);
    // Track per-deck iframe elements (e.g., YouTube embeds)
    const ytIframeRefs = useRef<Record<string, HTMLIFrameElement | null>>({});
    // Pollers for YT info (time, duration, title)
    const ytPollTimersRef = useRef<Record<string, number | null>>({});

    // (YouTube compatibility removed)

    // Monitor state: only one deck at a time; first deck -> Left, second -> Right
    const [monitorDeck, setMonitorDeck] = useState<string | null>(null);
    const [visible, setVisible] = useState(false);
    // VU meters (0..1 normalized)
    const [vuLevels, setVuLevels] = useState<Record<string, number>>({ track_1: 0, track_2: 0, mic: 0 });
    const [masterVu, setMasterVu] = useState<number>(0);

    // Keep latest decks in a ref for event handlers
    useEffect(() => { decksRef.current = decks; }, [decks]);

    // Tempo and BPM states
    useEffect(() => {
        const t1 = new Audio("/nui/audio/track_1.mp3");
        const t2 = new Audio("/nui/audio/track_2.mp3");
        t1.loop = false;
        t2.loop = false;
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

        // Create master bus (for local monitoring) and a separate broadcast bus (for recording/stream)
        const masterBus = ctx.createGain();
        masterBus.gain.value = 1.0;
        masterBus.connect(ctx.destination);
        masterBusRef.current = masterBus;
        monitorConnectedRef.current = true;
        const broadcastBus = ctx.createGain();
        broadcastBus.gain.value = 1.0;
        broadcastBusRef.current = broadcastBus;
        // Master analyser (tap the master bus)
        try {
            const masterAnalyser = ctx.createAnalyser();
            masterAnalyser.smoothingTimeConstant = 0.8;
            masterAnalyser.fftSize = 1024;
            masterBus.connect(masterAnalyser);
            masterAnalyserRef.current = masterAnalyser;
        } catch {}
        try {
            const streamDest = ctx.createMediaStreamDestination();
            streamDestRef.current = streamDest;
            // Route broadcast bus to the recording stream; keep master bus for headphones/room
            broadcastBus.connect(streamDest);
        } catch {}

        const makeChain = (el: HTMLAudioElement) => {
            const source = ctx.createMediaElementSource(el);
            const gain = ctx.createGain();
            const panner = ctx.createStereoPanner();
            let analyser: AnalyserNode | undefined;
            try {
                analyser = ctx.createAnalyser();
                analyser.smoothingTimeConstant = 0.8;
                analyser.fftSize = 1024;
            } catch {}
            // Route each deck into master bus (for monitoring via panners)
            // and also into broadcast bus (pre-panner) so monitoring pan doesn't affect stream
            source.connect(gain);
            gain.connect(panner).connect(masterBus);
            try { if (analyser) { gain.connect(analyser); } } catch {}
            try {
                broadcastBusRef.current && gain.connect(broadcastBusRef.current);
            } catch {}
            return { source, gain, panner, analyser };
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
        const onEnded1 = () => { try { advancePlaylist("track_1"); } catch {} };
        const onEnded2 = () => { try { advancePlaylist("track_2"); } catch {} };
        t1.addEventListener("ended", onEnded1);
        t2.addEventListener("ended", onEnded2);

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
            t1.removeEventListener("ended", onEnded1);
            t2.removeEventListener("ended", onEnded2);
            t1.pause();
            t2.pause();
            try {
                nodesRef.current["track_1"]?.source.disconnect();
                nodesRef.current["track_1"]?.gain.disconnect();
                nodesRef.current["track_1"]?.panner.disconnect();
                nodesRef.current["track_1"]?.altSource?.disconnect();
                nodesRef.current["track_2"]?.source.disconnect();
                nodesRef.current["track_2"]?.gain.disconnect();
                nodesRef.current["track_2"]?.panner.disconnect();
                nodesRef.current["track_2"]?.altSource?.disconnect();
            } catch {}
            // Remove any remaining iframes
            try { ytIframeRefs.current["track_1"]?.remove(); ytIframeRefs.current["track_1"] = null; } catch {}
            try { ytIframeRefs.current["track_2"]?.remove(); ytIframeRefs.current["track_2"] = null; } catch {}
            // do not close ctx to avoid pops; it will be GC'ed on page unload
            cancelled = true;
        };
    }, []);

    // Expose helpers for debugging / programmatic access
    useEffect(() => {
        (window as any).__getMusicAudioContext = () => audioCtxRef.current;
        (window as any).__getMusicMixStream = () => streamDestRef.current?.stream ?? null;
    }, []);

    // NUI helpers
    const getParentResource = (): string => {
        try {
            const fn = (window as any).GetParentResourceName;
            if (typeof fn === "function") return fn();
        } catch {}
        return "pickle_clubs";
    };
    const nuiPost = async (name: string, data?: any) => {
        const resource = getParentResource();
        try {
            await fetch(`https://${resource}/${name}`, {
                method: "POST",
                headers: { "Content-Type": "application/json; charset=utf-8" },
                body: JSON.stringify(data ?? {}),
            });
        } catch (e) {
            console.error("MusicController: NUI POST failed", name, e);
        }
    };
    const nuiPostJson = async <T,>(name: string, data?: any): Promise<T | null> => {
        const resource = getParentResource();
        try {
            const res = await fetch(`https://${resource}/${name}`, {
                method: "POST",
                headers: { "Content-Type": "application/json; charset=utf-8" },
                body: JSON.stringify(data ?? {}),
            });
            const txt = await res.text();
            try { return JSON.parse(txt) as T; } catch { return null; }
        } catch (e) {
            console.error("MusicController: NUI POST JSON failed", name, e);
            return null;
        }
    };
    type TurnConfig = {
        iceServers?: Array<{ urls: string[] | string; username?: string; credential?: string; }>;
    };
    const sleep = (ms: number) => new Promise<void>(r => setTimeout(r, ms));
    const fetchTurnConfig = async (): Promise<RTCConfiguration> => {
        let requested = false;
        for (let i = 0; i < 15; i++) {
            const cfg = await nuiPostJson<{ ok: boolean; config?: TurnConfig }>("music_rtc_get_turn_config", {});
            const c = (cfg && cfg.config) ? cfg.config : null;
            const valid = !!(c && Array.isArray(c.iceServers) && c.iceServers.length > 0);
            if (valid) {
                return { iceServers: c!.iceServers as any };
            }
            if (!requested) {
                requested = true;
                await nuiPost("music_rtc_request_turn_config", {});
            }
            await sleep(200);
        }
        return {};
    };

    // (no-op placeholder removed: chunk-based streaming is no longer used)

    const startBroadcast = async () => {
        if (isBroadcasting) return;
        const ctx = audioCtxRef.current;
        const streamNode = streamDestRef.current;
        if (!ctx || !streamNode) return;
        try { await ctx.resume?.(); } catch {}

        const stream = streamNode.stream;
        const audioTracks = stream.getAudioTracks();
        outboundTrackRef.current = (audioTracks && audioTracks[0]) ? audioTracks[0] : null;

        const streamId = `${Date.now()}_${Math.random().toString(36).slice(2)}`;
        streamIdRef.current = streamId;
        await nuiPost("music_rtc_announce_broadcast", { streamId });
        console.log("MusicController: broadcast announced", { streamId, hasTrack: !!outboundTrackRef.current });
        setIsBroadcasting(true);
        try {
            (window as any).__musicBroadcastStreamId = streamId;
            (window as any).__musicIsBroadcaster = true;
        } catch {}
    };

    const stopBroadcast = async () => {
        if (!isBroadcasting) return;
        setIsBroadcasting(false);
        await nuiPost("music_rtc_stop_broadcast", {});
        const map = peerMapRef.current;
        for (const k of Object.keys(map)) {
            const id = Number(k);
            const pc = map[id];
            try { pc.onicecandidate = null; } catch {}
            try { pc.ontrack = null; } catch {}
            try { pc.getSenders().forEach(s => { try { pc.removeTrack(s); } catch {} }); } catch {}
            try { pc.close(); } catch {}
            delete map[id];
        }
        peerMapRef.current = {};
        outboundTrackRef.current = null;
        streamIdRef.current = null;
        try {
            (window as any).__musicIsBroadcaster = false;
            (window as any).__musicBroadcastStreamId = null;
        } catch {}
        // turn off mic if enabled
        try {
            if (isMicOn) {
                // disconnect and stop
                try { micSourceRef.current?.disconnect(); } catch {}
                try { micGainRef.current?.disconnect(); } catch {}
				try { micAnalyserRef.current?.disconnect(); } catch {}
                try { micStreamRef.current?.getTracks().forEach(t => { try { t.stop(); } catch {} }); } catch {}
                micSourceRef.current = null;
                micGainRef.current = null;
                micStreamRef.current = null;
				micAnalyserRef.current = null;
                setIsMicOn(false);
            }
        } catch {}
    };

    const ensureBroadcasterPeer = async (listenerId: number): Promise<RTCPeerConnection | null> => {
        const existing = peerMapRef.current[listenerId];
        if (existing) return existing;
        const cfg = await fetchTurnConfig();
        const pc = new RTCPeerConnection(cfg);
        try {
            pc.onconnectionstatechange = () => console.log("MusicController RTC connectionState:", pc.connectionState, "to", listenerId);
            pc.oniceconnectionstatechange = () => console.log("MusicController RTC iceConnectionState:", pc.iceConnectionState, "to", listenerId);
            pc.onicegatheringstatechange = () => console.log("MusicController RTC gatheringState:", pc.iceGatheringState, "to", listenerId);
        } catch {}
        pc.onicecandidate = (ev) => {
            if (ev.candidate) {
                nuiPost("music_rtc_ice_to_listener", { to: listenerId, candidate: ev.candidate });
            }
        };
        const stream = streamDestRef.current?.stream || null;
        const track = outboundTrackRef.current || (stream ? stream.getAudioTracks()[0] : null);
        if (track && stream) {
            try { 
                pc.addTrack(track, stream);
                console.log("MusicController: added outbound track to peer", { listenerId, enabled: track.enabled, muted: (track as any).muted });
                try {
                    (track as any).onmute = () => console.warn("MusicController: outbound track muted");
                    (track as any).onunmute = () => console.warn("MusicController: outbound track unmuted");
                    (track as any).onended = () => console.warn("MusicController: outbound track ended");
                } catch {}
            } catch (e) {
                console.error("MusicController: addTrack failed", e);
            }
            outboundTrackRef.current = track;
        }
        peerMapRef.current[listenerId] = pc;
        return pc;
    };

    useNuiEvent("music:rtc:offer", async (msg: any) => {
        if (!isBroadcasting) return;
        const payload = (msg && (msg.payload || msg.data)) || {};
        const from = Number(payload.from);
        const sdp = payload.sdp;
        if (!from || !sdp) return;
        console.log("MusicController: received offer from", from);
        const pc = await ensureBroadcasterPeer(from);
        if (!pc) return;
        try {
            await pc.setRemoteDescription({ type: "offer", sdp });
            const answer = await pc.createAnswer();
            await pc.setLocalDescription(answer);
            await nuiPost("music_rtc_answer", { to: from, sdp: answer.sdp });
            console.log("MusicController: sent answer to", from);
        } catch {}
    });

    useNuiEvent("music:rtc:iceFromListener", async (msg: any) => {
        if (!isBroadcasting) return;
        const payload = (msg && (msg.payload || msg.data)) || {};
        const from = Number(payload.from);
        let candidate = payload.candidate;
        if (!from || !candidate) return;
        const pc = peerMapRef.current[from];
        if (!pc) return;
        try {
            // Normalize candidate possibly sent as JSON string
            if (typeof candidate === "string") {
                try { candidate = JSON.parse(candidate); } catch {}
            }
            await pc.addIceCandidate(candidate as RTCIceCandidateInit);
            console.log("MusicController: added ICE candidate from", from);
        } catch {}
    });

    // Auto-start broadcasting once decks/graph are ready
    useEffect(() => {
        // Start once when both decks are initialized and stream node exists
        if (isBroadcasting) return;
        if (!decks.track_1 || !decks.track_2) return;
        if (!audioCtxRef.current || !streamDestRef.current) return;
        // Best-effort kickoff (safe to call if already recording due to guard above)
        startBroadcast();
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [!!decks.track_1, !!decks.track_2]);

    // Stop broadcasting on unmount if still active
    useEffect(() => {
        return () => {
            if (isBroadcasting) {
                stopBroadcast();
            }
            // mic cleanup on unmount
            try { micSourceRef.current?.disconnect(); } catch {}
            try { micGainRef.current?.disconnect(); } catch {}
            try { micStreamRef.current?.getTracks().forEach(t => { try { t.stop(); } catch {} }); } catch {}
            try { navigator.mediaDevices?.removeEventListener?.("devicechange", onDeviceChange); } catch {}
            // stop YT polling
            try {
                (["track_1", "track_2"] as const).forEach(d => {
                    const t = ytPollTimersRef.current[d];
                    if (t) { clearInterval(t); ytPollTimersRef.current[d] = null; }
                });
            } catch {}
        };
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [isBroadcasting]);

    // While broadcasting, prevent any local monitor output for the broadcaster,
    // but keep the broadcast bus feeding the MediaStream destination.
    useEffect(() => {
        const ctx = audioCtxRef.current;
        const master = masterBusRef.current;
        if (!ctx || !master) return;
        try {
            if (isBroadcasting) {
                if (monitorConnectedRef.current) {
                    try { master.disconnect(ctx.destination); } catch {}
                    monitorConnectedRef.current = false;
                }
            } else {
                if (!monitorConnectedRef.current) {
                    try { master.connect(ctx.destination); } catch {}
                    monitorConnectedRef.current = true;
                }
            }
        } catch {}
    }, [isBroadcasting]);

    // (YouTube IFrame API removed)

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

    // Push playbackRate updates to active YouTube players when tempo changes
    useEffect(() => {
        (["track_1", "track_2"] as const).forEach((deck) => {
            const d = decks[deck];
            if (!d) return;
            const curr = d.playlist?.find(x => x.id === d.currentItemId);
            if (!curr || curr.sourceType !== "youtube") return;
            const rate = d.tempo || 1;
            try { postMessageToYouTube(deck, "setPlaybackRate", [rate]); } catch {}
        });
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [decks.track_1?.tempo, decks.track_2?.tempo, decks.track_1?.currentItemId, decks.track_2?.currentItemId]);

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

    // (YouTube volume mapping removed)

    // (YouTube playback rate mapping removed)

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
    // Safely attempt to access an iframe's internal <video> when same-origin.
    // Returns null for cross-origin iframes (e.g., YouTube), which are not directly accessible.
    const tryGetIframeVideoElement = (deck: string): HTMLVideoElement | null => {
        try {
            const iframe = ytIframeRefs.current[deck];
            if (!iframe) return null;
            const doc = iframe.contentDocument || iframe.contentWindow?.document || null;
            if (!doc) return null;
            const video = doc.querySelector("video") as HTMLVideoElement | null;
            return video || null;
        } catch {
            // Cross-origin access throws; not allowed
            return null;
        }
    };

    // Send a command to a YouTube iframe using its postMessage API (no direct DOM access needed).
    const postMessageToYouTube = (deck: string, func: string, args: any[] = []) => {
        const frame = ytIframeRefs.current[deck];
        const win = frame?.contentWindow;
        if (!win) return;
        try {
            // The player listens for this message shape
            win.postMessage(JSON.stringify({ event: "command", func, args }), "*");
        } catch {}
    };

    // If an accessible iframe <video> is available, route it into the deck's gain chain.
    const attachIframeVideoToDeck = (deck: string, video: HTMLVideoElement) => {
        try {
            const ctx = audioCtxRef.current;
            if (!ctx) return;
            const chain = nodesRef.current[deck];
            if (!chain) return;
            // Disconnect any previous alternate source
            try { chain.altSource?.disconnect(); } catch {}
            chain.altSource = undefined;
            // Avoid double output (element -> speakers) since we route via WebAudio
            const src = ctx.createMediaElementSource(video);
            src.connect(chain.gain);
            chain.altSource = src;
            console.log("MusicController: attached iframe video to deck chain", { deck });
        } catch (e) {
            console.warn("MusicController: failed to attach iframe video to deck", deck, e);
        }
    };

    // Listen for YouTube iframe messages to sync title, currentTime, duration, and play state
    useEffect(() => {
        const onMessage = (ev: MessageEvent) => {
            // Only handle messages from known YT iframes
            try {
                if (!ev || !ev.data) return;
                const data = typeof ev.data === "string" ? (() => { try { return JSON.parse(ev.data); } catch { return null; } })() : ev.data;
                if (!data || typeof data !== "object") return;
                // Identify deck by matching source window
                let fromDeck: string | null = null;
                for (const key of Object.keys(ytIframeRefs.current)) {
                    const f = ytIframeRefs.current[key];
                    if (f && f.contentWindow === ev.source) { fromDeck = key; break; }
                }
                if (!fromDeck) return;
                const deck = fromDeck as "track_1" | "track_2";
                const evt = data.event;
                if (evt === "onReady") {
                    // Subscribe to updates and request initial info
                    postMessageToYouTube(deck, "addEventListener", ["infoDelivery"]);
                    postMessageToYouTube(deck, "addEventListener", ["onStateChange"]);
                    postMessageToYouTube(deck, "getVideoData");
                    postMessageToYouTube(deck, "getDuration");
                    postMessageToYouTube(deck, "getCurrentTime");
                    const t = decksRef.current[deck]?.tempo || 1;
                    try { postMessageToYouTube(deck, "setPlaybackRate", [t]); } catch {}
                    // Autoplay if previously playing
                    if (decksRef.current[deck]?.isPlaying) {
                        postMessageToYouTube(deck, "playVideo");
                    }
                    return;
                }
                if (evt === "onStateChange") {
                    const st = data.info;
                    if (st === 1) { // playing
                        setDecks(prev => prev[deck] ? ({ ...prev, [deck]: { ...prev[deck], isPlaying: true } }) : prev);
                    } else if (st === 2) { // paused
                        setDecks(prev => prev[deck] ? ({ ...prev, [deck]: { ...prev[deck], isPlaying: false } }) : prev);
                    } else if (st === 0) { // ended
                        // advance playlist
                        setTimeout(() => { try { advancePlaylist(deck); } catch {} }, 0);
                    }
                    return;
                }
                if (evt === "infoDelivery") {
                    const info = data.info || {};
                    // Sync time and duration
                    if (typeof info.currentTime === "number") {
                        setDecks(prev => prev[deck] ? ({ ...prev, [deck]: { ...prev[deck], currentTime: info.currentTime } }) : prev);
                    }
                    if (typeof info.duration === "number" && isFinite(info.duration)) {
                        setDecks(prev => prev[deck] ? ({ ...prev, [deck]: { ...prev[deck], duration: info.duration } }) : prev);
                    }
                    // Sync title when available
                    if (info.videoData && typeof info.videoData.title === "string" && info.videoData.title.trim().length > 0) {
                        const title = info.videoData.title.trim();
                        setDecks(prev => {
                            const pd = prev[deck];
                            if (!pd) return prev;
                            const list = pd.playlist || [];
                            const currId = pd.currentItemId;
                            const idx = list.findIndex(it => it.id === currId);
                            if (idx === -1) return prev;
                            const nextList = [...list];
                            nextList[idx] = { ...nextList[idx], title };
                            return { ...prev, [deck]: { ...pd, playlist: nextList } };
                        });
                    }
                    return;
                }
            } catch {}
        };
        window.addEventListener("message", onMessage);
        return () => window.removeEventListener("message", onMessage);
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []);

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

    const getNextPlaylistItemId = (deck: "track_1" | "track_2"): string | null => {
        const d = decksRef.current[deck];
        const list = d?.playlist || [];
        if (list.length === 0) return null;
        const currId = d?.currentItemId;
        const idx = list.findIndex(it => it.id === currId);
        const nextIdx = idx >= 0 ? (idx + 1) % list.length : 0;
        const nextItem = list[nextIdx];
        return nextItem ? nextItem.id : null;
    };

    const advancePlaylist = async (deck: "track_1" | "track_2") => {
        const nextId = getNextPlaylistItemId(deck);
        if (!nextId) return;
        await loadPlaylistItem(deck, nextId);
    };

    const addYoutubeUrlToPlaylist = async (deck: string, url: string) => {
        const item: PlaylistItem = {
            id: `${Date.now()}_${Math.random().toString(36).slice(2)}`,
            title: deriveTitleFromUrlOrName(url),
            src: url,
            sourceType: "youtube",
            baseBpm: null,
        };
        setDecks(prev => {
            const list = prev[deck]?.playlist || [];
            return { ...prev, [deck]: { ...prev[deck], playlist: [...list, item] } };
        });
    };

    const addUrlToPlaylist = async (deck: string, url: string) => {
        if (url.includes("youtube.com")) {
            await addYoutubeUrlToPlaylist(deck, url);
            return;
        }
        const item: PlaylistItem = {
            id: `${Date.now()}_${Math.random().toString(36).slice(2)}`,
            title: deriveTitleFromUrlOrName(url),
            src: url,
            sourceType: "url",
            baseBpm: null,
        };
        setDecks(prev => {
            const list = prev[deck]?.playlist || [];
            return { ...prev, [deck]: { ...prev[deck], playlist: [...list, item] } };
        });
        let bpm: number | null = null;
        bpm = await analyzeBpmForUrl(url);
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
    	const d = decksRef.current[deck];
    	if (!d?.audio) return;
    	const item = (d.playlist || []).find(x => x.id === itemId);
    	if (!item) return;
    	const wasPlaying = d.isPlaying === true;
    	// Configure audio element
    	if (item.sourceType === "youtube" && item.src) {
    		// Show YouTube video as iframe overlay (for visual, not for playback)
    		const ytIdMatch = item.src.match(/(?:youtu\.be\/|youtube\.com\/(?:embed\/|v\/|watch\?v=|watch\?.+&v=))([A-Za-z0-9_-]{11})/);
    		const ytId = ytIdMatch ? ytIdMatch[1] : null;
    		if (ytId) {
    			const ytIframe = document.createElement("iframe");
    			// Enable JS API so we can control via postMessage (still no raw DOM access)
    			const origin = (() => {
    				try { return window.location.origin; } catch { return ""; }
    			})();
    			ytIframe.src = `https://www.youtube.com/embed/${ytId}?autoplay=1&controls=1&playsinline=1&enablejsapi=1&origin=${origin}`;
    			ytIframe.allow = "autoplay; encrypted-media; fullscreen; picture-in-picture";
    			ytIframe.width = "320";
    			ytIframe.height = "180";
    			ytIframe.frameBorder = "0";
    			ytIframe.style.position = "absolute";
    			ytIframe.style.zIndex = "1000";
    			ytIframe.style.top = "10px";
    			ytIframe.style.left = "10px";
    			ytIframe.id = `yt-iframe-${deck}`;
    			document.body.appendChild(ytIframe);
    			// Track ref for safe access / postMessage control
    			ytIframeRefs.current[deck] = ytIframe;
                // Commit selection state for YouTube items as well
                setDecks(prev => {
                    const prevDeck = prev[deck];
                    if (!prevDeck) return prev;
                    return {
                        ...prev,
                        [deck]: {
                            ...prevDeck,
                            baseBpm: item.baseBpm ?? null,
                            currentTime: 0,
                            duration: 0,
                            isPlaying: false,
                            objectUrl: undefined,
                            currentItemId: item.id,
                        }
                    };
                });
     			ytIframe.onload = () => {
                    // Kick off handshake per YT embed protocol
                    try {
                        ytIframe.contentWindow?.postMessage(JSON.stringify({ event: "listening", id: ytIframe.id, channel: "widget" }), "*");
                    } catch {}
    				const v = tryGetIframeVideoElement(deck);
    				if (v) {
    					console.log("MusicController: iframe <video> accessible (same-origin)", { deck, video: v });
    					attachIframeVideoToDeck(deck, v);
    				} else {
    					console.log("MusicController: iframe <video> not accessible (likely cross-origin). Use postMessage API for control.", { deck });
    					// Example: notify player to start or query state
    					postMessageToYouTube(deck, "playVideo");
    				}
                    // Subscribe to events and fetch initial info
                    try {
                        postMessageToYouTube(deck, "addEventListener", ["onReady"]);
                        postMessageToYouTube(deck, "addEventListener", ["infoDelivery"]);
                        postMessageToYouTube(deck, "addEventListener", ["onStateChange"]);
                        postMessageToYouTube(deck, "getVideoData");
                        postMessageToYouTube(deck, "getDuration");
                        postMessageToYouTube(deck, "getCurrentTime");
                        const t = decksRef.current[deck]?.tempo || 1;
                        postMessageToYouTube(deck, "setPlaybackRate", [t]);
                    } catch {}
                    // Start polling for robustness
                    try {
                        // Clear any existing poller
                        const prev = ytPollTimersRef.current[deck];
                        if (prev) { clearInterval(prev); ytPollTimersRef.current[deck] = null; }
                        ytPollTimersRef.current[deck] = window.setInterval(() => {
                            postMessageToYouTube(deck, "getCurrentTime");
                            postMessageToYouTube(deck, "getDuration");
                            postMessageToYouTube(deck, "getVideoData");
                        }, 500);
                    } catch {}
    			};
    			// Remove any previous YouTube iframe for this deck when loading a new item or on cleanup
    			setTimeout(() => {
    				const prev = document.getElementById(`yt-iframe-${deck}`);
    				if (prev && prev !== ytIframe) prev.remove();
    			}, 100);
    		}
    	} else {
            // If a previous iframe-based source was attached, tear it down when switching to non-YouTube
            try {
                const chain = nodesRef.current[deck];
                if (chain?.altSource) {
                    try { chain.altSource.disconnect(); } catch {}
                    chain.altSource = undefined;
                }
            } catch {}
            try {
                const prevIframe = ytIframeRefs.current[deck];
                if (prevIframe) {
                    prevIframe.remove();
                    ytIframeRefs.current[deck] = null;
                }
            } catch {}
            // Stop any YT polling for this deck
            try {
                const t = ytPollTimersRef.current[deck];
                if (t) { clearInterval(t); ytPollTimersRef.current[deck] = null; }
            } catch {}
            try { d.audio.pause(); } catch {}
            try {
                d.audio.src = item.src;
                d.audio.currentTime = 0;
                d.audio.loop = false;
                d.audio.preload = "auto";
            } catch {}
            try {
                (d.audio as any).preservesPitch = false;
                (d.audio as any).mozPreservesPitch = false;
                (d.audio as any).webkitPreservesPitch = false;
            } catch {}
            try { d.audio.load(); } catch {}
            // Commit selection state
            setDecks(prev => {
                const prevDeck = prev[deck];
                if (!prevDeck) return prev;
                return {
                    ...prev,
                    [deck]: {
                        ...prevDeck,
                        baseBpm: item.baseBpm ?? null,
                        currentTime: 0,
                        duration: 0,
                        isPlaying: false,
                        objectUrl: item.sourceType === "file" ? item.src : undefined,
                        currentItemId: item.id,
                    }
                };
            });
            // Autoplay only if previously playing; guard current item
            const resumeIfNeeded = async () => {
                const latest = decksRef.current[deck];
                if (!latest || latest.currentItemId !== itemId) return;
                if (!wasPlaying) return;
                try { await audioCtxRef.current?.resume?.(); } catch {}
                try {
                    await latest.audio.play();
                    setDecks(prev => {
                        const pd = prev[deck];
                        if (!pd || pd.currentItemId !== itemId) return prev;
                        return { ...prev, [deck]: { ...pd, isPlaying: true } };
                    });
                } catch {}
            };
            try { d.audio.addEventListener("canplay", resumeIfNeeded, { once: true } as any); } catch {}
            // BPM analysis if missing
            if (item.baseBpm == null) {
                let bpm: number | null = null;
                if (item.sourceType === "url") {
                    bpm = await analyzeBpmForUrl(item.src);
                } else if (item.sourceType === "file") {
                    bpm = await (async () => {
                        try { const res = await fetch(item.src); const b = await res.blob(); return await analyzeBpmFromBlob(b); } catch { return null; }
                    })();
                }
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
        }
    };

    const removePlaylistItem = (deck: string, itemId: string) => {
        const d = decks[deck];
        if (!d) return;
        const item = d.playlist?.find(x => x.id === itemId);
        const wasCurrent = d.currentItemId === itemId;

        if (item) {
            // Revoke object URLs where appropriate
            if (item.sourceType === "file") {
                if (wasCurrent) {
                    try { if (d.objectUrl) URL.revokeObjectURL(d.objectUrl); } catch {}
                } else if (item.src !== d.audio.src) {
                    try { URL.revokeObjectURL(item.src); } catch {}
                }
            }
            // If removing the currently loaded item, stop playback and clear sources
            if (wasCurrent) {
                try { d.audio.pause(); } catch {}
                try { d.audio.src = ""; } catch {}
                try { d.audio.removeAttribute("src"); } catch {}
                try { d.audio.currentTime = 0; d.audio.load(); } catch {}
                // Disconnect any iframe-based alt source and remove iframe
                try {
                    const chain = nodesRef.current[deck];
                    if (chain?.altSource) {
                        try { chain.altSource.disconnect(); } catch {}
                        chain.altSource = undefined;
                    }
                } catch {}
                try {
                    const prevIframe = ytIframeRefs.current[deck];
                    if (prevIframe) {
                        prevIframe.remove();
                        ytIframeRefs.current[deck] = null;
                    }
                } catch {}
            }
        }

        setDecks(prev => {
            const list = prev[deck]?.playlist || [];
            const next = list.filter(it => it.id !== itemId);
            const wasCurrentPrev = prev[deck]?.currentItemId === itemId;
            if (!prev[deck]) return prev;
            const nextDeck = wasCurrentPrev
                ? { ...prev[deck], playlist: next, currentItemId: null, isPlaying: false, currentTime: 0, duration: 0, objectUrl: undefined }
                : { ...prev[deck], playlist: next };
            return { ...prev, [deck]: nextDeck };
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
        const currentItem = d.playlist?.find(x => x.id === d.currentItemId);

        // If no current item (e.g., it was deleted), allow stopping any lingering playback
        if (!currentItem) {
            try { d.audio.pause(); } catch {}
            setDecks(prev => ({ ...prev, [deck]: { ...prev[deck], isPlaying: false } }));
            return;
        }

        // Handle YouTube items via postMessage API
        if (currentItem.sourceType === "youtube") {
            if (d.isPlaying) {
                postMessageToYouTube(deck, "pauseVideo");
                setDecks(prev => ({ ...prev, [deck]: { ...prev[deck], isPlaying: false } }));
            } else {
                try { await audioCtxRef.current?.resume?.(); } catch {}
                postMessageToYouTube(deck, "playVideo");
                setDecks(prev => ({ ...prev, [deck]: { ...prev[deck], isPlaying: true } }));
            }
            return;
        }

        // HTML audio handling
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

    // (VU Meter moved into RangeControl component)

    useNuiEvent("music:setControllerVisible", (data: any) => {
        setVisible(data.visible);
    });

    // Horizontal VU meter (mic-only) using same segment style as vertical
    function HorizontalVu({ level }: { level: number }) {
        const segments = 12;
        const lit = Math.max(0, Math.min(segments, Math.round(level * segments)));
        const segs: JSX.Element[] = [];
        for (let i = 0; i < segments; i++) {
            const idxFromLeft = i + 1;
            const on = idxFromLeft <= lit;
            let color = "#18a058";
            const frac = idxFromLeft / segments;
            if (frac >= 0.85) color = "#d64545";
            else if (frac >= 0.65) color = "#c8a43b";
            segs.push(
                <div
                    key={i}
                    style={{
                        flex: 1,
                        minWidth: 4,
                        height: 6,
                        borderRadius: 1,
                        background: on ? color : "#1e1e1e",
                    }}
                />
            );
        }
        return (
            <div
                style={{
                    width: "100%",
                    height: 10,
                    background: "#0b0b0b",
                    border: "1px solid #333",
                    borderRadius: 3,
                    display: "flex",
                    flexDirection: "row",
                    alignItems: "center",
                    padding: 1,
                    gap: 1,
                }}
            >
                {segs}
            </div>
        );
    }

    // Mic toggle handlers
    const enableMic = async () => {
        if (isMicOn) return;
        try {
            const ctx = audioCtxRef.current;
            const bus = broadcastBusRef.current;
            if (!ctx || !bus) return;
            try { await ctx.resume?.(); } catch {}
            const audioConstraints: MediaTrackConstraints = { echoCancellation: true, noiseSuppression: true, autoGainControl: true } as any;
            if (selectedMicId && selectedMicId !== "default") {
                (audioConstraints as any).deviceId = { exact: selectedMicId };
            }
            const stream = await navigator.mediaDevices.getUserMedia({ audio: audioConstraints });
            const source = ctx.createMediaStreamSource(stream);
            const gain = ctx.createGain();
            gain.gain.value = 1.0;
            source.connect(gain);
            gain.connect(bus);
			// Tap mic signal for VU meter
			try {
				const analyser = ctx.createAnalyser();
				analyser.smoothingTimeConstant = 0.8;
				analyser.fftSize = 1024;
				gain.connect(analyser);
				micAnalyserRef.current = analyser;
			} catch {}
            micStreamRef.current = stream;
            micSourceRef.current = source;
            micGainRef.current = gain;
            setIsMicOn(true);
            // After permission, refresh device labels
            try { await enumerateMicDevices(); } catch {}
        } catch (e) {
            console.error("MusicController: enableMic failed", e);
        }
    };
    const disableMic = () => {
        if (!isMicOn) return;
        try { micSourceRef.current?.disconnect(); } catch {}
        try { micGainRef.current?.disconnect(); } catch {}
		try { micAnalyserRef.current?.disconnect(); } catch {}
        try { micStreamRef.current?.getTracks().forEach(t => { try { t.stop(); } catch {} }); } catch {}
        micSourceRef.current = null;
        micGainRef.current = null;
        micStreamRef.current = null;
		micAnalyserRef.current = null;
        setIsMicOn(false);
    };
    const toggleMic = async () => {
        if (isMicOn) return disableMic();
        await enableMic();
    };
    // When changing device while mic is on, hot-switch by restarting mic
    useEffect(() => {
        (async () => {
            if (isMicOn) {
                try { disableMic(); } catch {}
                await enableMic();
            }
        })();
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [selectedMicId]);

    // Enumerate audio input devices
    const enumerateMicDevices = async () => {
        try {
            const list = await navigator.mediaDevices?.enumerateDevices?.();
            if (!list) return;
            const inputs = list.filter(d => d.kind === "audioinput");
            setMicDevices(inputs);
            // Initialize selection if none yet
            if (selectedMicId == null) {
                const def = inputs.find(d => d.deviceId === "default") || inputs[0];
                setSelectedMicId(def ? def.deviceId : null);
            }
        } catch {}
    };
    const onDeviceChange = () => { enumerateMicDevices(); };
    useEffect(() => {
        enumerateMicDevices();
        try { navigator.mediaDevices?.addEventListener?.("devicechange", onDeviceChange); } catch {}
        return () => { try { navigator.mediaDevices?.removeEventListener?.("devicechange", onDeviceChange); } catch {} };
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []);

    // --- VU meter sampling loop ---
    useEffect(() => {
        let raf = 0;
        const computeLevel = (an: AnalyserNode | null | undefined): number => {
            if (!an) return 0;
            const size = an.fftSize || 1024;
            const buf = new Float32Array(size);
            try {
                an.getFloatTimeDomainData(buf);
            } catch {
                return 0;
            }
            let sumSq = 0;
            let peak = 0;
            for (let i = 0; i < buf.length; i++) {
                const v = buf[i];
                sumSq += v * v;
                const a = v < 0 ? -v : v;
                if (a > peak) peak = a;
            }
            const rms = Math.sqrt(sumSq / (buf.length || 1));
            // Map to 0..1 with ~60 dB dynamic window; mix RMS and peak for responsiveness
            const db = 20 * Math.log10(rms + 1e-8);
            let norm = (db + 60) / 60;
            if (norm < 0) norm = 0;
            if (norm > 1) norm = 1;
            const mixed = Math.max(norm * 0.7 + peak * 0.3, 0);
            return mixed > 1 ? 1 : mixed;
        };
        const tick = () => {
            const a1 = nodesRef.current["track_1"]?.analyser;
            const a2 = nodesRef.current["track_2"]?.analyser;
            const am = masterAnalyserRef.current;
			const ami = micAnalyserRef.current;
			const l1 = computeLevel(a1);
			const l2 = computeLevel(a2);
			const lm = computeLevel(am);
			const lmi = computeLevel(ami);
            setVuLevels(prev => {
				const n = { ...prev, track_1: l1, track_2: l2, mic: lmi };
				return (prev.track_1 !== n.track_1 || prev.track_2 !== n.track_2 || prev.mic !== n.mic) ? n : prev;
            });
            setMasterVu(prev => (Math.abs(prev - lm) > 0.01 ? lm : prev));
            raf = requestAnimationFrame(tick);
        };
        raf = requestAnimationFrame(tick);
        return () => cancelAnimationFrame(raf);
    }, []);

    // Keyboard shortcut handler: ESC/Backspace to hide controller
    useEffect(() => {
        const handleKeyDown = (e: KeyboardEvent) => {
            if (
                (e.key === "Escape" || e.key === "Esc" || e.key === "Backspace")
                && visible
            ) {
                fetchNui("setVisible", { visible: false });
                e.preventDefault();
            }
        };
        window.addEventListener("keydown", handleKeyDown);
        return () => {
            window.removeEventListener("keydown", handleKeyDown);
        };
    }, [visible]);

    return (decks.track_1 && decks.track_2 && visible) ? (
        <div className="bg-background p-4 rounded-md absolute bottom-[20px] left-[50%] translate-x-[-50%]" style={{ display: "flex", flexDirection: "column", width: "1280px" }}>
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
                    width: 30px;
                    height: 30px;
                    min-width: 30px;
                    min-height: 30px;
                    display: flex;
                    align-items: center;
                    justify-content: center;
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
                    width: 232px;
                    display: flex;
                    flex-direction: column;
                    gap: 8px;
                    overflow-y: scroll;
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
                    width: 37px;
                    height: 100%;
                    display: flex;
                    flex-direction: column;
                    align-items: center;
                    gap: 6px;
                }
                .vRange {
                    -webkit-appearance: slider-vertical; /* Chrome/Edge/Safari */
                    appearance: auto;
                    writing-mode: bt-lr; /* Firefox */
                    width: 100%; /* thickness; keep in sync with thumb width for look */
                    height: 12px; /* fill the group */
                    transform: rotate(90deg);
                    flex: 1; /* take remaining vertical space between label and bottom info */
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
                    transform: rotate(90deg);
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
                /* Digital VU meter */
                .vu {
                    width: 10px;
                    height: 100%;
                    background: #0b0b0b;
                    border: 1px solid #333;
                    border-radius: 3px;
                    display: flex;
                    flex-direction: column-reverse;
                    padding: 1px;
                    gap: 1px;
                }
                .vuSeg {
                    flex: 1;
                    min-height: 4px;
                    border-radius: 1px;
                    background: #1e1e1e;
                }
                `}
            </style>
            <div style={{ display: "flex", gap: 16 }}>
                {Object.keys({track_1: decks.track_1, controls: decks.controls, track_2: decks.track_2}).map(function(deck) {
                    if (deck === "controls") {
                        return (
                            <div style={{ display: "flex", flexDirection: "column", gap: 8, alignItems: "center", justifyContent: "center"  }}>
                                <div className="mixerRow h-[220px]" style={{ gap: 24, justifyContent: "center" }}>
                                    <div className="vGroup">
                                        <RangeControl
                                            orientation="vertical"
                                            label="Right"
                                            valueText={"Left"}
                                            min={0}
                                            max={100}
                                            step={1}
                                            value={Math.round(crossfade * 100)}
                                            onChange={(v) => setCrossfade(v / 100)}
                                            ariaLabel="Crossfader"
                                        />
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
                                        <RangeControl
                                            orientation="vertical"
                                            min={0}
                                            max={100}
                                            step={1}
                                            value={Math.round(masterVolume * 100)}
                                            onChange={(v) => setMasterVolume(v / 100)}
                                            ariaLabel="Master volume"
                                            showVu={true}
                                            vuLevel={masterVu}
                                            label="Master"
                                            valueText={`${Math.round(masterVolume * 100)}%`}
                                        />
                                        <button
                                            className="resetBtn"
                                            onClick={() => setMasterVolume(1)}
                                            aria-label="Reset master volume"
                                            title="Reset master volume"
                                        >
                                            ↺
                                        </button>
                                    </div>
                                </div>
                                <div className="mixerRow w-full" style={{ gap: 12, justifyContent: "center" }}>
                                    <button
                                        className="bg-secondary px-4 w-full py-2 rounded-md text-secondary-foreground shadow-xs hover:bg-secondary/80"
                                        onClick={isBroadcasting ? stopBroadcast : startBroadcast}
                                        aria-label="Start broadcasting mix to clients"
                                        title="Start broadcasting mix to clients"
                                    >
                                        {isBroadcasting ? "Stop Broadcasting" : "Start Broadcasting"}
                                    </button>
                                </div>
                                 <div style={{ display: "flex", flexDirection: "column", gap: 6, width: "100%" }}>
                                    <div style={{ display: "flex", flexDirection: "row", alignItems: "center", gap: 6, width: "100%" }}>
                                    <button
                                        className="resetBtn"
                                        onClick={toggleMic}
                                        aria-label={isMicOn ? "Turn off mic" : "Turn on mic"}
                                        title={isMicOn ? "Turn off mic" : "Turn on mic"}
                                    >
                                        {isMicOn ? 
                                            <Mic className="w-4 h-4 text-green-500" />
                                        :
                                            <MicOff className="w-4 h-4 text-red-500" />
                                        }
                                    </button>
                                        <select
                                        id="micDevice"
                                        value={selectedMicId ?? ""}
                                        onChange={(e) => setSelectedMicId(e.target.value || null)}
                                        style={{ width: "100%", background: "#0f0f0f", color: "#eee", border: "1px solid #333", borderRadius: 6, padding: "4px 6px" }}
                                    >
                                        {micDevices.length === 0 ? (
                                            <option value="">No inputs</option>
                                        ) : (
                                            micDevices.map((d, idx) => (
                                                <option key={d.deviceId || idx} value={d.deviceId}>
                                                    {d.label || `Microphone ${idx + 1}`}
                                                </option>
                                            ))
                                        )}
                                    </select>
                                    </div>
                                    <HorizontalVu level={vuLevels.mic} />
                                </div>
                            </div>
                        )
                    } else {
                        const playlistCol = (
                            <div className="playlistCol bg-secondary h-full">
                                <div style={{ display: "flex", flexDirection: "column", gap: 6, width: "100%", alignItems: "stretch" }}>
                                    <div
                                        className="cursor-pointer hover:bg-primary/10 transition-colors duration-200 px-4"
                                        style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 8, width: "100%", paddingTop: 8, paddingBottom: 8, borderBottom: "1px solid #222" }}
                                        onClick={(e) => { e.stopPropagation(); setAddDialogDeck(deck as "track_1" | "track_2"); setIsAddDialogOpen(true); }}
                                    >
                                        <div style={{ display: "flex", alignItems: "center", gap: 8, minWidth: 0 }}>
                                            <div className="text-sm" style={{ display: "flex", alignItems: "center", gap: 8, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", maxWidth: 220 }}>
                                                <Plus className="w-4 h-4" />
                                                Add Song to Playlist
                                            </div>
                                        </div>
                                    </div>
                                    {(decks[deck].playlist ?? []).map(item => (
                                        <div className="cursor-pointer hover:bg-primary/10 transition-colors duration-200 px-4" key={item.id} onClick={() => loadPlaylistItem(deck, item.id)} style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 8, width: "100%" }}>
                                            <div style={{ display: "flex", alignItems: "center", gap: 8, minWidth: 0 }}>
                                                <div style={{ minWidth: 6, width: 6, minHeight: 6, height: 6, borderRadius: 999, background: decks[deck].currentItemId === item.id ? "#60d394" : "#555" }} />
                                                <div className="text-xs" style={{ whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", maxWidth: 220 }}>{item.title}</div>
                                                {typeof item.baseBpm === "number" ? (
                                                    <span style={{ opacity: 0.7, fontSize: 12, whiteSpace: "nowrap" }}>• {item.baseBpm.toFixed(0)} BPM</span>
                                                ) : (null)}
                                            </div>
                                            <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
                                                <button
                                                    className="text-xs hover:text-red-500"
                                                    onClick={(e) => { e.stopPropagation(); removePlaylistItem(deck, item.id); }}
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
                                            <span>Now Playing:</span>
                                            <strong style={{ maxWidth: 220, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
                                                {decks[deck].playlist?.find(x => x.id === decks[deck].currentItemId)?.title || "—"}
                                            </strong>
                                        </div>
                                        <div className="controls" style={{ width: "100%", justifyContent: "center" }}>
                                            <span>{formatTime(decks[deck].currentTime)}</span>
                                            <RangeControl
                                                min={0}
                                                max={Math.max(0, decks[deck].duration || 0)}
                                                step={0.01}
                                                value={Math.min(decks[deck].currentTime || 0, decks[deck].duration || 0)}
                                                onChange={(to) => {
                                                    const curr = decks[deck];
                                                    const currentItem = curr.playlist?.find(x => x.id === curr.currentItemId);
                                                    if (currentItem?.sourceType === "youtube") {
                                                        postMessageToYouTube(deck, "seekTo", [to, true]);
                                                        setDecks(prev => ({ ...prev, [deck]: { ...prev[deck], currentTime: to } }));
                                                    } else {
                                                        curr.audio.currentTime = to;
                                                        setDecks(prev => ({ ...prev, [deck]: { ...prev[deck], currentTime: to } }));
                                                    }
                                                }}
                                                ariaLabel={`${deck} position`}
                                                disabled={!decks[deck].duration || decks[deck].duration === 0}
                                            />
                                            <span>{formatTime(decks[deck].duration)}</span>
                                        </div>
                                        {/* (YouTube container removed) */}
                                        <div className="controls h-[220px]" style={{ width: "100%", justifyContent: "center", gap: 24 }}>
                                            {deck === "track_2" && playlistCol}
                                            <div className="vGroup">
                                                <RangeControl
                                                    orientation="vertical"
                                                    min={50}
                                                    max={150}
                                                    step={1}
                                                    value={Math.round(decks[deck].tempo * 100)}
                                                    onChange={(v) => {
                                                        const nextTempo = v / 100;
                                                        setDecks(prev => ({ ...prev, [deck]: { ...prev[deck], tempo: nextTempo } }));
                                                        // If YouTube, push rate immediately
                                                        const currentItem = decks[deck].playlist?.find(x => x.id === decks[deck].currentItemId);
                                                        if (currentItem?.sourceType === "youtube") {
                                                            postMessageToYouTube(deck, "setPlaybackRate", [nextTempo]);
                                                        }
                                                    }}
                                                    ariaLabel={`${deck} tempo`}
													label="Tempo"
													valueText={decks[deck].baseBpm ? `${Math.round(decks[deck].baseBpm * decks[deck].tempo)} BPM` : "—"}
                                                />
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
                                                <RangeControl
                                                    orientation="vertical"
                                                    min={0}
                                                    max={100}
                                                    step={1}
                                                    value={Math.round((decks[deck].deckVolume ?? 1) * 100)}
                                                    onChange={(raw) => {
                                                        const v = raw / 100;
                                                        setDecks(prev => ({ ...prev, [deck]: { ...prev[deck], deckVolume: v } }));
                                                    }}
                                                    ariaLabel={`${deck} volume`}
                                                    showVu={true}
                                                    vuLevel={vuLevels[deck] ?? 0}
													label="Volume"
													valueText={`${Math.round((decks[deck].deckVolume ?? 1) * 100)}%`}
                                                />
                                                <button
                                                    className="resetBtn"
                                                    onClick={() => setDecks(prev => ({ ...prev, [deck]: { ...prev[deck], deckVolume: 1 } }))}
                                                    aria-label={`${deck} reset volume`}
                                                    title="Reset volume"
                                                >
                                                    ↺
                                                </button>
                                            </div>
                                            {deck === "track_1" && playlistCol}
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
                                        className="bg-secondary px-4 py-2 rounded-md text-secondary-foreground shadow-xs hover:bg-secondary/80"
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
								<div style={{ marginBottom: 4, opacity: 0.8 }}>Upload Files</div>
								<label className="bg-secondary px-4 py-2 rounded-md text-secondary-foreground shadow-xs hover:bg-secondary/80" style={{ display: "inline-flex", alignItems: "center", gap: 6, cursor: "pointer" }}>
									<input
										type="file"
										accept="audio/*"
										multiple
										style={{ display: "none" }}
										onChange={async (e) => {
											const files = e.target.files;
											if (files && files.length > 0) {
												for (const file of Array.from(files)) {
													await addFileToPlaylist(addDialogDeck, file);
												}
												setIsAddDialogOpen(false);
											}
											if (e.currentTarget) e.currentTarget.value = "";
										}}
									/>
									<span>Choose Files…</span>
								</label>
							</div>
                        </div>
                    </div>
                </div>
            )}
        </div>
    ) : null;
}