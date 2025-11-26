import { useEffect, useRef, useState } from "react";
import { useNuiEvent } from "../../providers/nui/useNui";

function base64ToArrayBuffer(b64: string): ArrayBuffer {
	const binary = atob(b64);
	const len = binary.length;
	const bytes = new Uint8Array(len);
	for (let i = 0; i < len; i++) bytes[i] = binary.charCodeAt(i);
	return bytes.buffer;
}

export default function MusicPlayer() {
	const audioRef = useRef<HTMLAudioElement | null>(null);
	const mediaSourceRef = useRef<MediaSource | null>(null);
	const sourceBufferRef = useRef<SourceBuffer | null>(null);
	const currentStreamIdRef = useRef<string | null>(null);
	const [isPlaying, setIsPlaying] = useState(false);
	const lastSeqRef = useRef<Record<string, number>>({});
	const LIVE_LATENCY_SEC = 1.2; // larger buffer to reduce underruns/pops
	const RETAIN_WINDOW_SEC = 30; // keep last 30s to prevent quota and reduce churn
	const lastSeekAtRef = useRef<number>(0);
	const nextSeqRef = useRef<number>(-1);
	const chunkMapRef = useRef<Map<number, ArrayBuffer>>(new Map());
	const firstAppendDoneRef = useRef<boolean>(false);

	// Debug: catch-all NUI message logger to verify delivery
	useEffect(() => {
		const listener = (ev: MessageEvent) => {
			const t = (ev && (ev as any).data && (ev as any).data.type) || "";
			if (t && (t.startsWith("music:"))) {
				console.log("MusicPlayer: caught NUI message", t, (ev as any).data);
			}
		};
		window.addEventListener("message", listener);
		return () => window.removeEventListener("message", listener);
	}, []);
	const tryAppend = () => {
		const sb = sourceBufferRef.current;
		const ms = mediaSourceRef.current;
		if (!ms || ms.readyState !== "open") return;
		if (!sb || sb.updating) return;
		// Drain in-order chunks and coalesce a small batch to reduce append churn
		let count = 0;
		let total = 0;
		const parts: ArrayBuffer[] = [];
		while (nextSeqRef.current >= 0 && chunkMapRef.current.has(nextSeqRef.current) && count < 1 && total < 300000) {
			const ab = chunkMapRef.current.get(nextSeqRef.current)!;
			chunkMapRef.current.delete(nextSeqRef.current);
			parts.push(ab);
			total += ab.byteLength;
			nextSeqRef.current++;
			count++;
		}
		if (parts.length === 0) return;
		try {
			let toAppend: ArrayBuffer;
			if (parts.length === 1) {
				toAppend = parts[0];
			} else {
				const out = new Uint8Array(total);
				let offset = 0;
				for (const p of parts) {
					out.set(new Uint8Array(p), offset);
					offset += p.byteLength;
				}
				toAppend = out.buffer;
			}
			sb.appendBuffer(toAppend);
			if (!firstAppendDoneRef.current) firstAppendDoneRef.current = true;
		} catch (e) {
			console.warn("MusicPlayer: appendBuffer failed", e);
		}
	};

	const chooseSupportedMimeType = (incoming: string): string | null => {
		const MS: any = (window as any).MediaSource || (window as any).WebKitMediaSource;
		if (!MS || typeof MS.isTypeSupported !== "function") return incoming;
		const normalize = (mt: string) => {
			return mt.replace(/codecs=opus/gi, 'codecs="opus"').replace(/codecs=vorbis/gi, 'codecs="vorbis"');
		};
		const candidates = [
			normalize(incoming),
			'audio/webm; codecs="opus"',
			"audio/webm",
			'audio/ogg; codecs="opus"',
		];
		for (const c of candidates) {
			try {
				if (MS.isTypeSupported(c)) return c;
			} catch {}
		}
		return null;
	};

	// Listen for NUI events instead of raw window messages
	useNuiEvent("music:streamStart", (msg: any) => {
		const payload = (msg && (msg.payload || msg.data)) || {};
		const { streamId, mimeType } = payload;
		if (!streamId || !mimeType) return;
		try {
			if ((window as any).__musicBroadcastStreamId && (window as any).__musicBroadcastStreamId === streamId) {
				console.log("MusicPlayer: ignoring local broadcast stream", streamId);
				return;
			}
		} catch {}
		currentStreamIdRef.current = streamId;
		lastSeqRef.current[streamId] = -1;
		nextSeqRef.current = -1;
		try { chunkMapRef.current.clear(); } catch {}

		const ms = new MediaSource();
		mediaSourceRef.current = ms;
		const audio = audioRef.current;
		if (!audio) return;
		audio.src = URL.createObjectURL(ms);
		audio.muted = false;
		audio.volume = 1.0;
		try { audio.load(); } catch {}

		ms.addEventListener("sourceended", () => console.log("MusicPlayer: MediaSource ended"));
		ms.addEventListener("sourceclose", () => console.log("MusicPlayer: MediaSource closed"));
		ms.addEventListener("error", (e: any) => console.error("MusicPlayer: MediaSource error", e));
		audio.addEventListener("error", () => {
			const err = (audio.error && audio.error.message) || audio.error;
			console.error("MusicPlayer: <audio> error", err);
		}, { once: true });
		audio.addEventListener("canplay", () => {
			console.log("MusicPlayer: <audio> canplay");
		});
		audio.addEventListener("playing", () => {
			console.log("MusicPlayer: <audio> playing");
		});
		audio.addEventListener("waiting", () => {
			console.log("MusicPlayer: <audio> waiting");
			try {
				const b = sourceBufferRef.current;
				if (b && b.buffered && b.buffered.length > 0) {
					const end = b.buffered.end(b.buffered.length - 1);
					if (Number.isFinite(end)) {
						const now = performance.now?.() || Date.now();
						if (now - (lastSeekAtRef.current || 0) > 120) {
							audio.currentTime = Math.max(0, end - LIVE_LATENCY_SEC);
							lastSeekAtRef.current = now;
						}
					}
				}
			} catch {}
		});

		const chosenType = chooseSupportedMimeType(String(mimeType));
		if (!chosenType) {
			console.warn("MusicPlayer: No supported MSE mimeType for", mimeType);
			return;
		}

		ms.addEventListener("sourceopen", () => {
			try {
				try { (ms as any).duration = Infinity; } catch {}
				const sb = ms.addSourceBuffer(chosenType);
				sourceBufferRef.current = sb;
				sb.mode = "sequence";
				try {
					// Allow full timeline; we'll manage chasing in audio.currentTime
					(sb as any).appendWindowStart = 0;
					(sb as any).appendWindowEnd = Number.POSITIVE_INFINITY;
				} catch {}
				sb.addEventListener("error", (e) => {
					console.error("MusicPlayer: SourceBuffer error", e);
				});
				sb.addEventListener("updateend", () => {
					try {
						const a = audioRef.current;
						const b = sourceBufferRef.current;
						if (a && b && b.buffered && b.buffered.length > 0) {
							const end = b.buffered.end(b.buffered.length - 1);
							console.log("MusicPlayer: updateend, buffered end", end.toFixed(3), "currentTime", a.currentTime.toFixed(3));
							if ((a.paused || a.ended) && (end - (a.currentTime || 0)) >= (LIVE_LATENCY_SEC * 0.8)) {
								try { a.currentTime = Math.max(0, end - LIVE_LATENCY_SEC); } catch {}
								a.play().then(() => setIsPlaying(true)).catch(() => {});
							}
							// Fallback: if first append happened but still paused after 1s, force a play attempt
							if (firstAppendDoneRef.current) {
								setTimeout(() => {
									const aa = audioRef.current;
									const bb = sourceBufferRef.current;
									if (!aa || !bb) return;
									if (aa.paused || aa.ended) {
										try {
											if (bb.buffered && bb.buffered.length > 0) {
												const e2 = bb.buffered.end(bb.buffered.length - 1);
												aa.currentTime = Math.max(0, e2 - LIVE_LATENCY_SEC);
											}
										} catch {}
										aa.play().then(() => setIsPlaying(true)).catch(() => {});
									}
								}, 1000);
							}
							// Evict old data to keep buffer small and avoid quota / parser churn
							try {
								const start = b.buffered.start(0);
								const safeKeepFrom = Math.max(0, a.currentTime - RETAIN_WINDOW_SEC);
								if (start < safeKeepFrom && !b.updating) {
									b.remove(0, safeKeepFrom);
								}
							} catch {}
						}
					} catch {}
					tryAppend();
				});
				tryAppend();
			} catch {
				console.warn("MusicPlayer: addSourceBuffer failed for", chosenType);
			}
		}, { once: true });

		// Defer play until we have enough buffered
		setIsPlaying(false);
		console.log("music:streamStart", payload);
	});

	useNuiEvent("music:streamChunk", (msg: any) => {
		const payload = (msg && (msg.payload || msg.data)) || {};
		const { streamId, base64, seq } = payload;
		if (!streamId || streamId !== currentStreamIdRef.current) return;
		if (!base64) return;
		// Deduplicate out-of-order or duplicate chunks
		const last = lastSeqRef.current[streamId] ?? -1;
		const nseq = typeof seq === "number" ? seq : last + 1;
		if (nseq <= last) return;
		lastSeqRef.current[streamId] = nseq;
		const ab = base64ToArrayBuffer(base64);
		// Initialize next expected sequence on first arrival
		if (nextSeqRef.current < 0) nextSeqRef.current = nseq;
		// Drop ancient packets; store future packets
		if (nseq < nextSeqRef.current) {
			// too old; ignore
		} else if (!chunkMapRef.current.has(nseq)) {
			chunkMapRef.current.set(nseq, ab);
		}
		tryAppend();
		console.log("music:streamChunk", payload);
	});

	useNuiEvent("music:streamStop", (msg: any) => {
		const payload = (msg && (msg.payload || msg.data)) || {};
		const { streamId } = payload;
		if (!streamId || streamId !== currentStreamIdRef.current) return;
		try {
			if (sourceBufferRef.current && mediaSourceRef.current?.readyState === "open") {
				if (!sourceBufferRef.current.updating) {
					mediaSourceRef.current.endOfStream();
				} else {
					sourceBufferRef.current.addEventListener("updateend", () => {
						try { mediaSourceRef.current?.endOfStream(); } catch {}
					}, { once: true });
				}
			}
		} catch {}
		setIsPlaying(false);
	});

	// Cleanup on unmount
	useEffect(() => {
		return () => {
			try {
				if (sourceBufferRef.current) {
					sourceBufferRef.current.removeEventListener("updateend", tryAppend);
				}
			} catch {}
			sourceBufferRef.current = null;
			mediaSourceRef.current = null;
			currentStreamIdRef.current = null;
			try { chunkMapRef.current.clear(); } catch {}
			nextSeqRef.current = -1;
		};
	}, []);

	return (
		<div style={{ position: "fixed", left: -9999, top: -9999, width: 1, height: 1, opacity: 0, pointerEvents: "none" }}>
			<audio ref={audioRef} playsInline autoPlay />
			<div aria-hidden style={{ width: 1, height: 1 }}>{isPlaying ? "on" : "off"}</div>
		</div>
	);
}

