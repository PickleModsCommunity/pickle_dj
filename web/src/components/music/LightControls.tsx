import { useState, useEffect } from "react";
import { fetchNui } from "@/providers/nui/fetchNui";
import { useNuiEvent } from "../../providers/nui/useNui";

type LightType = "ambient" | "spotlight" | "barlight";
type FlashSetting = "off" | "low" | "high";

interface LightControlState {
    enabled: boolean;
    rotateHorizontal: boolean;
    rotateVertical: boolean;
    flash: FlashSetting;
}

interface LightControlsProps {
    lightType: LightType;
    label: string;
    stationId: number | null;
    initialState?: LightControlState;
}

// Helper to convert flash number to string
// Values match GetFlashString in shared.lua: 0 = off, 10 = low, 2 = high
function flashNumberToString(flash: number): FlashSetting {
    if (flash === 0) return "off";
    if (flash === 10) return "low";
    if (flash === 2) return "high";
    return "off"; // default
}

export default function LightControls({ lightType, label, stationId, initialState }: LightControlsProps) {
    const [state, setState] = useState<LightControlState>(
        initialState || {
            enabled: true,
            rotateHorizontal: true,
            rotateVertical: false,
            flash: "low",
        }
    );

    // Listen for initial state from server
    useNuiEvent("music:lightControlsState", (event: any) => {
        const data = event.data || event;
        // Only process if stationId matches and we have valid data
        if (!stationId || data.stationId !== stationId) return;
        if (!data.controls || !data.controls.lights || !data.controls.lights[lightType]) return;
        
        const lightControl = data.controls.lights[lightType];
        if (lightControl) {
            // Flash value is already converted to string by client, use directly or convert if number
            let flashValue: FlashSetting = "off";
            if (typeof lightControl.flash === "string") {
                flashValue = lightControl.flash as FlashSetting;
            } else if (typeof lightControl.flash === "number") {
                flashValue = flashNumberToString(lightControl.flash);
            }
            
            // Ensure boolean values are properly handled (defensive checks)
            const enabled = lightControl.enabled === true || (lightControl.enabled !== false && lightControl.enabled !== 0 && lightControl.enabled !== "false");
            const rotateHorizontal = lightControl.rotateHorizontal === true || lightControl.rotateHorizontal === 1 || lightControl.rotateHorizontal === "true";
            const rotateVertical = lightControl.rotateVertical === true || lightControl.rotateVertical === 1 || lightControl.rotateVertical === "true";
            
            setState({
                enabled: enabled,
                rotateHorizontal: rotateHorizontal,
                rotateVertical: rotateVertical,
                flash: flashValue,
            });
        }
    });

    // Listen for networked updates
    useNuiEvent("music:lightControlsUpdated", (event: any) => {
        const data = event.data || event;
        if (data.stationId === stationId && data.lightType === lightType) {
            if (data.property === "enabled") {
                // Handle boolean values defensively
                const enabled = data.value === true || data.value === 1 || data.value === "true";
                setState(prev => ({ ...prev, enabled: enabled }));
            } else if (data.property === "rotateHorizontal" || data.property === "rotateVertical") {
                // Handle boolean values defensively
                const boolValue = data.value === true || data.value === 1 || data.value === "true";
                setState(prev => ({ ...prev, [data.property]: boolValue }));
            } else if (data.property === "flash") {
                setState(prev => ({ ...prev, flash: data.value as FlashSetting }));
            }
        }
    });

    const updateControl = async (property: keyof LightControlState, value: boolean | FlashSetting) => {
        if (!stationId) return;
        
        // Only send update to server - don't update state optimistically
        // State will be updated when we receive the networked update from server
        await fetchNui("updateLightControls", {
            stationId,
            lightType,
            property,
            value,
        });
    };

    const cycleFlash = () => {
        const nextFlash: FlashSetting = 
            state.flash === "off" ? "low" :
            state.flash === "low" ? "high" : "off";
        updateControl("flash", nextFlash);
    };

    return (
        <div style={{ display: "flex", flexDirection: "column", gap: 8, alignItems: "center", minWidth: 80 }}>
            <div style={{ fontSize: 12, fontWeight: 500, color: "#ddd", marginBottom: 4 }}>
                {label}
            </div>
            
            {/* Enable/Disable Toggle */}
            <button
                onClick={() => updateControl("enabled", !state.enabled)}
                style={{
                    width: 48,
                    height: 48,
                    border: `2px solid ${state.enabled ? "#60d394" : "#d64545"}`,
                    borderRadius: 6,
                    background: state.enabled ? "rgba(96, 211, 148, 0.1)" : "rgba(214, 69, 69, 0.1)",
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "center",
                    cursor: "pointer",
                    transition: "all 120ms ease",
                }}
                title={state.enabled ? "Turn off light" : "Turn on light"}
                aria-label={state.enabled ? "Turn off light" : "Turn on light"}
            >
                {state.enabled ? (
                    <svg
                        width="24"
                        height="24"
                        viewBox="0 0 24 24"
                        fill="none"
                        stroke="#60d394"
                        strokeWidth="2"
                        strokeLinecap="round"
                        strokeLinejoin="round"
                    >
                        <circle cx="12" cy="12" r="5" />
                        <path d="M12 1v6M12 17v6M4.22 4.22l4.24 4.24M15.54 15.54l4.24 4.24M1 12h6M17 12h6M4.22 19.78l4.24-4.24M15.54 8.46l4.24-4.24" />
                    </svg>
                ) : (
                    <svg
                        width="24"
                        height="24"
                        viewBox="0 0 24 24"
                        fill="none"
                        stroke="#d64545"
                        strokeWidth="2"
                        strokeLinecap="round"
                        strokeLinejoin="round"
                    >
                        <circle cx="12" cy="12" r="5" />
                        <line x1="12" y1="1" x2="12" y2="3" />
                        <line x1="12" y1="21" x2="12" y2="23" />
                        <line x1="4.22" y1="4.22" x2="5.64" y2="5.64" />
                        <line x1="18.36" y1="18.36" x2="19.78" y2="19.78" />
                        <line x1="1" y1="12" x2="3" y2="12" />
                        <line x1="21" y1="12" x2="23" y2="12" />
                        <line x1="4.22" y1="19.78" x2="5.64" y2="18.36" />
                        <line x1="18.36" y1="5.64" x2="19.78" y2="4.22" />
                    </svg>
                )}
            </button>
            
            {/* Rotate Horizontal Toggle */}
            <button
                onClick={() => updateControl("rotateHorizontal", !state.rotateHorizontal)}
                style={{
                    width: 48,
                    height: 48,
                    border: `2px solid ${state.rotateHorizontal ? "#60d394" : "#555"}`,
                    borderRadius: 6,
                    background: state.rotateHorizontal ? "rgba(96, 211, 148, 0.1)" : "#1e1e1e",
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "center",
                    cursor: "pointer",
                    transition: "all 120ms ease",
                }}
                title="Rotate Horizontal"
                aria-label="Toggle horizontal rotation"
            >
                <svg
                    width="24"
                    height="24"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke={state.rotateHorizontal ? "#60d394" : "#888"}
                    strokeWidth="2"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                >
                    <path d="M21 12H3M18 7l3-3-3-3M6 7L3 4l3-3" />
                </svg>
            </button>

            {/* Rotate Vertical Toggle */}
            <button
                onClick={() => updateControl("rotateVertical", !state.rotateVertical)}
                style={{
                    width: 48,
                    height: 48,
                    border: `2px solid ${state.rotateVertical ? "#60d394" : "#555"}`,
                    borderRadius: 6,
                    background: state.rotateVertical ? "rgba(96, 211, 148, 0.1)" : "#1e1e1e",
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "center",
                    cursor: "pointer",
                    transition: "all 120ms ease",
                }}
                title="Rotate Vertical"
                aria-label="Toggle vertical rotation"
            >
                <svg
                    width="24"
                    height="24"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke={state.rotateVertical ? "#60d394" : "#888"}
                    strokeWidth="2"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                >
                    <path d="M12 21V3M7 18l-5-5 5-5M17 18l5-5-5-5" />
                </svg>
            </button>

            {/* Flash Control (3-state: off, low, high) */}
            <button
                onClick={cycleFlash}
                style={{
                    width: 48,
                    height: 48,
                    border: `2px solid ${
                        state.flash === "off" ? "#555" :
                        state.flash === "low" ? "#c8a43b" : "#d64545"
                    }`,
                    borderRadius: 6,
                    background: state.flash === "off" ? "#1e1e1e" :
                        state.flash === "low" ? "rgba(200, 164, 59, 0.1)" : "rgba(214, 69, 69, 0.1)",
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "center",
                    cursor: "pointer",
                    transition: "all 120ms ease",
                    flexDirection: "column",
                    gap: 2,
                }}
                title={`Flash: ${state.flash}`}
                aria-label={`Flash setting: ${state.flash}`}
            >
                {state.flash === "off" ? (
                    <svg
                        width="20"
                        height="20"
                        viewBox="0 0 24 24"
                        fill="none"
                        stroke="#888"
                        strokeWidth="2"
                        strokeLinecap="round"
                        strokeLinejoin="round"
                    >
                        <path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z" />
                        <line x1="2" y1="2" x2="22" y2="22" stroke="#888" strokeWidth="2" />
                    </svg>
                ) : state.flash === "low" ? (
                    <svg
                        width="20"
                        height="20"
                        viewBox="0 0 24 24"
                        fill="none"
                        stroke="#c8a43b"
                        strokeWidth="2"
                        strokeLinecap="round"
                        strokeLinejoin="round"
                    >
                        <path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z" />
                    </svg>
                ) : (
                    <svg
                        width="20"
                        height="20"
                        viewBox="0 0 24 24"
                        fill="none"
                        stroke="#d64545"
                        strokeWidth="2"
                        strokeLinecap="round"
                        strokeLinejoin="round"
                    >
                        <path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z" />
                        <circle cx="18" cy="6" r="2" fill="#d64545" opacity="0.6" />
                    </svg>
                )}
                <span style={{ fontSize: 8, color: state.flash === "off" ? "#888" : state.flash === "low" ? "#c8a43b" : "#d64545", textTransform: "uppercase", fontWeight: 600 }}>
                    {state.flash}
                </span>
            </button>
        </div>
    );
}
