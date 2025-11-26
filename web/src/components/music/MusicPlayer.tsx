import { useEffect, useRef, useState } from "react";

type IncomingMessage =
	| { type: "music:streamStart"; payload: { streamId: string; mimeType: string } }
	| { type: "music:streamChunk"; payload: { streamId: string; seq: number; base64: string } }
	| { type: "music:streamStop"; payload: { streamId: string } }
	| { type: string; payload?: any };

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
	const pendingQueueRef = useRef<ArrayBuffer[]>([]);
	const currentStreamIdRef = useRef<string | null>(null);
	const [isPlaying, setIsPlaying] = useState(false);

	const tryAppend = () => {
		const sb = sourceBufferRef.current;
		if (!sb || sb.updating) return;
		const next = pendingQueueRef.current.shift();
		if (!next) return;
		try {
			sb.appendBuffer(next);
		} catch {
			// If append fails (e.g., buffer full), drop or retry later
		}
	};

	useEffect(() => {
		function handleMessage(event: MessageEvent) {
			const data: IncomingMessage = event?.data;
			if (!data || typeof data !== "object") return;

			if (data.type === "music:streamStart") {
				const { streamId, mimeType } = data.payload;
				currentStreamIdRef.current = streamId;
				pendingQueueRef.current = [];

				const ms = new MediaSource();
				mediaSourceRef.current = ms;
				const audio = audioRef.current;
				if (!audio) return;
				audio.src = URL.createObjectURL(ms);

				ms.addEventListener("sourceopen", () => {
					try {
						const sb = ms.addSourceBuffer(mimeType);
						sourceBufferRef.current = sb;
						sb.mode = "sequence";
						sb.addEventListener("updateend", tryAppend);
					} catch {
						// unsupported mimeType
					}
				}, { once: true });

				audio.play().catch(() => {});
				setIsPlaying(true);
			} else if (data.type === "music:streamChunk") {
				const { streamId, base64 } = data.payload;
				if (streamId !== currentStreamIdRef.current) return;
				const ab = base64ToArrayBuffer(base64);
				pendingQueueRef.current.push(ab);
				tryAppend();
			} else if (data.type === "music:streamStop") {
				const { streamId } = data.payload;
				if (streamId !== currentStreamIdRef.current) return;
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
			}
		}

		window.addEventListener("message", handleMessage);
		return () => {
			window.removeEventListener("message", handleMessage);
			try {
				if (sourceBufferRef.current) {
					sourceBufferRef.current.removeEventListener("updateend", tryAppend);
				}
			} catch {}
			sourceBufferRef.current = null;
			mediaSourceRef.current = null;
			currentStreamIdRef.current = null;
			pendingQueueRef.current = [];
		};
	}, []);

	return (
		<div style={{ position: "fixed", left: -9999, top: -9999, width: 1, height: 1, opacity: 0, pointerEvents: "none" }}>
			<audio ref={audioRef} playsInline autoPlay />
			<div aria-hidden style={{ width: 1, height: 1 }}>{isPlaying ? "on" : "off"}</div>
		</div>
	);
}

