(function () {
	"use strict";

	const DEFAULT_RESOLUTION_ENABLED = false;
	const DEFAULT_RESOLUTION_SCALE = 80;
	const DEFAULT_FPS_ENABLED = false;
	const DEFAULT_FPS_TARGET = 60;
	const MIN_FPS_TARGET = 20;
	const MAX_FPS_TARGET = 240;
	const DEFAULT_GPM_DEVICE_LEVEL_ENABLED = true;
	const DEFAULT_HIDE_UUID_ENABLED = false;
	const DEFAULT_CONTROLLER_MODE_ENABLED = false;
	const DEFAULT_GPU_DISPLAY_ENABLED = false;
	const DEFAULT_GRAPHIC_API_DISPLAY_ENABLED = false;
	const DEFAULT_PLATFORM_DISPLAY_ENABLED = false;
	const DEFAULT_GRAPHIC_LIBRARY_ENABLED = false;
	const DEFAULT_GRAPHIC_LIBRARY = "opengl";
	const DEFAULT_CROSS_PLATFORM_ENABLED = false;
	const DEFAULT_CROSS_PLATFORM = "mobile";
	const DEFAULT_DEVICE_CHECKS_FORCED = false;
	const EXEC_TIMEOUT_MS = 10 * 60 * 1000;

	const advancedDefaults = { hp15: true, patch_1: true, patch_2: true, renderer: true, hp15_watcher: true, renderer_watcher: true };
	const DEFAULT_PIXELFLOW_PATCH_ENABLED = false;
	const DEFAULT_PIXELFLOW_CHOICE = "disabled";
	let callbackCounter = 0;
	let busy = false;
    let selectedPackage = "";
    let contextToken = "";
    let statusGeneration = 0;
    let dirty = false;
    let sharedDirty = false;
    let statusLoaded = false;
    let lastData = null;
    let mandatoryControls = [];
    let profileDefaults = {};
    const gameSelectorSection = document.getElementById("game-selector-section");
    const gameSelector = document.getElementById("game-selector");
    const selectedPackageNote = document.getElementById("selected-package");
    const mandatoryStatusList = document.getElementById("mandatory-status-list");
    const mandatoryControlsList = document.getElementById("mandatory-controls-list");

	const statusCard = document.getElementById("status-card");
	const statusDot = document.getElementById("status-dot");
	const statusTitle = document.getElementById("status-title");
	const statusDetail = document.getElementById("status-detail");
	const gameVersion = document.getElementById("game-version");
	const profileStatus = document.getElementById("profile-status");
	const libuePath = document.getElementById("libue-path");
	const libueStatus = document.getElementById("libue-status");
	const hp15Path = document.getElementById("hp15-path");
	const hp15Modify = document.getElementById("hp15-modify");
	const rendererConfigState = document.getElementById("renderer-config-state");
	const deviceChecksForceControl = document.getElementById("device-checks-force-control");
	const forceDeviceChecksEnabled = document.getElementById("force-device-checks-enabled");
	const advancedControl = document.getElementById("advanced-control");
	const enableHp15 = document.getElementById("enable-hp15");
	const enableRenderer = document.getElementById("enable-renderer");
	const enableHp15Watcher = document.getElementById("enable-hp15-watcher");
	const enableRendererWatcher = document.getElementById("enable-renderer-watcher");
	const enableGler = document.getElementById("enable-gler");
	const glerConfigState = document.getElementById("gler-config-state");
	const gpm7GlerWarning = document.getElementById("gpm7-gler-warning");
	const gpuCacheState = document.getElementById("gpu-cache-state");
	const gpuCacheResetButton = document.getElementById("gpu-cache-reset-button");
	const ueiniSection = document.getElementById("ueini-section");
	const ueiniState = document.getElementById("ueini-state");
	const ueiniEnabled = document.getElementById("ueini-enabled");

	const resolutionSection = document.getElementById("resolution-section");
	const resolutionBinaryState = document.getElementById("resolution-binary-state");
	const resolutionEnabled = document.getElementById("resolution-enabled");
	const resolutionScale = document.getElementById("resolution-scale");

	const fpsSection = document.getElementById("fps-section");
	const fpsBinaryState = document.getElementById("fps-binary-state");
	const fpsEnabled = document.getElementById("fps-enabled");
	const fpsDescription = document.getElementById("fps-description");
	const fpsTarget = document.getElementById("fps-target");

	const pixelflowSection = document.getElementById("pixelflow-section");
	const pixelflowBinaryState = document.getElementById("pixelflow-binary-state");
	const pixelflowPatchEnabled = document.getElementById("pixelflow-patch-enabled");
	const pixelflowMode = document.getElementById("pixelflow-mode");

	const gpmDeviceLevelSection = document.getElementById("gpm-device-level-section");
	const gpmDeviceLevelBinaryState = document.getElementById("gpm-device-level-binary-state");
	const gpmDeviceLevelEnabled = document.getElementById("gpm-device-level-enabled");

	const graphicLibrarySection = document.getElementById("graphic-library-section");
	const graphicLibraryBinaryState = document.getElementById("graphic-library-binary-state");
	const graphicLibraryEnabled = document.getElementById("graphic-library-enabled");
	const graphicLibrary = document.getElementById("graphic-library");

	const crossPlatformSection = document.getElementById("cross-platform-section");
	const crossPlatformBinaryState = document.getElementById("cross-platform-binary-state");
	const crossPlatformEnabled = document.getElementById("cross-platform-enabled");
	const crossPlatform = document.getElementById("cross-platform");

	const hideUuidSection = document.getElementById("hide-uuid-section");
	const controllerModeSection = document.getElementById("controller-mode-section");
	const hideUuidBinaryState = document.getElementById("hide-uuid-binary-state");
	const controllerModeBinaryState = document.getElementById("controller-mode-binary-state");
	const hideUuidEnabled = document.getElementById("hide-uuid-enabled");
	const controllerModeEnabled = document.getElementById("controller-mode-enabled");
	const gpuDisplaySection = document.getElementById("gpu-display-section");
	const gpuDisplayBinaryState = document.getElementById("gpu-display-binary-state");
	const gpuDisplayEnabled = document.getElementById("gpu-display-enabled");

	const graphicApiDisplaySection = document.getElementById("graphic-api-display-section");
	const graphicApiDisplayBinaryState = document.getElementById("graphic-api-display-binary-state");
	const graphicApiDisplayEnabled = document.getElementById("graphic-api-display-enabled");
	const platformDisplayEnabled = document.getElementById("platform-display-enabled");

	const form = document.getElementById("settings-form");
	const defaultButton = document.getElementById("default-button");
	const repairButton = document.getElementById("repair-button");
	const saveButton = document.getElementById("save-button");
	const managedControls = [controllerModeEnabled, hideUuidEnabled, pixelflowPatchEnabled, pixelflowMode, resolutionEnabled, resolutionScale, fpsEnabled, fpsTarget, gpmDeviceLevelEnabled, graphicLibraryEnabled, graphicLibrary, crossPlatformEnabled, crossPlatform, gpuDisplayEnabled, graphicApiDisplayEnabled, platformDisplayEnabled, forceDeviceChecksEnabled, enableHp15, enableRenderer, enableHp15Watcher, enableRendererWatcher, enableGler, defaultButton, repairButton, saveButton, gameSelector];

	function setStatus(kind, title, detail) {
		statusDot.className = `status-dot ${kind || ""}`.trim();
		statusTitle.textContent = title;
		statusDetail.textContent = detail;
	}

	function setBusy(value, action) {
		busy = value;
		document.body.classList.toggle("is-busy", value);
		statusCard.classList.toggle("processing", value);
		for (const control of [...managedControls, ...mandatoryControls.map(p => p.control)]) control.disabled = value || control.dataset.unsupported === "1";
        for (const control of [saveButton, repairButton]) control.disabled = value || !statusLoaded;
		saveButton.textContent = value && action === "save" ? "Saving…" : "Save";
		repairButton.textContent = value && action === "repair" ? "Repairing…" : "Repair";
	}

	function allowPaint() {
		return new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
	}

	function shellQuote(value) {
		return `'${String(value).replace(/'/g, `'"'"'`)}'`;
	}

	function rootExec(command, options) {
		if (!window.ksu || typeof window.ksu.exec !== "function") {
			return Promise.reject(new Error("No KernelSU WebUI root bridge was detected. Open this page from KernelSU Manager or a compatible module WebUI host."));
		}

		return new Promise((resolve, reject) => {
			const callbackName = `mho_mumu_exec_${Date.now()}_${callbackCounter++}`;
			const timeoutId = window.setTimeout(() => {
				delete window[callbackName];
				reject(new Error("The root operation did not answer within 10 minutes. It may still be finishing in the background; wait before retrying."));
			}, EXEC_TIMEOUT_MS);
			window[callbackName] = (errno, stdout, stderr) => {
				window.clearTimeout(timeoutId);
				delete window[callbackName];
				resolve({ errno: Number(errno), stdout: String(stdout || ""), stderr: String(stderr || "") });
			};
			try {
				window.ksu.exec(command, JSON.stringify(options || {}), callbackName);
			} catch (error) {
				window.clearTimeout(timeoutId);
				delete window[callbackName];
				reject(error);
			}
		});
	}

	function moduleCommand(args) {
		const quotedArgs = args.map(shellQuote).join(" ");
		return `set -e; m=/data/adb/modules/mho_mumu_patcher; [ -d "$m" ] || m=/data/adb/modules_update/mho_mumu_patcher; [ -x "$m/apply_patch.sh" ] || { echo "Module patch script not found" >&2; exit 45; }; "$m/apply_patch.sh" ${quotedArgs}`;
	}

	async function runModule(args) {
		const result = await rootExec(moduleCommand(args));
		if (result.errno !== 0) {
			throw new Error((result.stderr || result.stdout).trim() || `Module command failed with exit ${result.errno}.`);
		}
		return result.stdout;
	}

	function parseStatus(text) {
		const result = {};
		for (const line of String(text).split(/\r?\n/)) {
			const index = line.indexOf("=");
			if (index <= 0) continue;
			result[line.slice(0, index)] = line.slice(index + 1);
		}
		return result;
	}

	function clearStateClasses(element) {
		element.classList.remove("state-good", "state-info", "state-warn", "state-bad");
	}

	function setMandatoryState(element, displayState) {
		clearStateClasses(element);
		if (displayState === "Applied" || displayState === "Forced") element.classList.add("state-good");
		else if (displayState === "Not Required") element.classList.add("state-info");
		else if (displayState === "Not Applied") element.classList.add("state-bad");
		else element.classList.add("state-warn");
	}

	function setOptionalState(element, state) {
		clearStateClasses(element);
		if (state === "applied") element.classList.add("state-good");
		else if (state === "original") element.classList.add("state-warn");
		else element.classList.add("state-bad");
	}

	function setProfileState(element, supported) {
		clearStateClasses(element);
		element.classList.add(supported ? "state-good" : "state-bad");
	}

	function setRendererState(element, state) {
		clearStateClasses(element);
		if (state === "applied" || state === "not_required") element.classList.add("state-good");
		else if (state === "not_checked") element.classList.add("state-info");
		else if (state === "needs_patch") element.classList.add("state-warn");
		else element.classList.add("state-bad");
	}

	function setHp15State(element, state) {
		clearStateClasses(element);
		if (state === "override" || state === "compatible") element.classList.add("state-good");
		else if (state === "not_checked") element.classList.add("state-info");
		else if (state === "not_present") element.classList.add("state-info");
		else if (state === "needs_override") element.classList.add("state-bad");
		else element.classList.add("state-bad");
	}

	function setGlerState(element, state) {
		clearStateClasses(element);
		if (state === "applied") element.classList.add("state-good");
		else if (state === "absent") element.classList.add("state-warn");
		else element.classList.add("state-bad");
	}

	function setUeiniState(element, state) {
		clearStateClasses(element);
		if (state === "applied") element.classList.add("state-good");
		else if (state === "disabled") element.classList.add("state-info");
		else element.classList.add("state-warn");
	}

	function prettyUeiniState(value) {
		if (value === "applied") return "Applied";
		if (value === "disabled") return "Disabled";
		if (value === "stale") return "Needs Re-apply";
		return "Unavailable";
	}

	function prettyPatchState(value) {
		if (value === "applied") return "Applied";
		if (value === "not_required") return "Not Required";
		if (value === "needs_patch") return "Pending";
		if (value === "original") return "Not Applied";
		if (value === "unknown") return "Unknown";
		if (value === "not_checked") return "Not Monitored";
		if (value === "legacy_applied") return "Update Required";
		if (value === "unsupported") return "Not Supported";
		return "Unavailable";
	}

	function applyStatus(data, loadControls) {
        lastData = data;
        statusLoaded = true;
        contextToken = data.context_token || "";
        profileDefaults = Object.fromEntries(Object.entries(data).filter(([k]) => k.startsWith("default_")).map(([k, v]) => [k.slice(8), v]));
        renderMandatory(data, loadControls);
        for (const control of [defaultButton]) {
            control.dataset.unsupported = data.profile_supported === "1" && contextToken ? "0" : "1";
            control.disabled = busy || control.dataset.unsupported === "1";
        }
		for (const key of Object.keys(advancedDefaults)) {
			advancedDefaults[key] = data[`advanced_${key}_default_enabled`] !== "0";
		}
		gameVersion.textContent = data.game_version || "Unknown";

		const supported = data.profile_supported === "1";
		profileStatus.textContent = supported ? `${data.profile_id || "Supported"} · ${data.profile_status || "Unspecified"}` : "Unsupported";
		setProfileState(profileStatus, supported);
		libuePath.textContent = data.library || "No libUnreal found";
		libueStatus.textContent = data.library ? "Found" : "Not Found";
		const hp15State = data.hp15_state || "not_present";
		hp15Path.textContent = data.hp15_effective_path || "/data/system/etc/mumu-configs/shared_libs/libhp15_x86_64.so";
		if (hp15State === "override") hp15Modify.textContent = "Patched";
		else if (hp15State === "compatible") hp15Modify.textContent = data.hp15_modify ? "Date: " + data.hp15_modify : "Compatible";
		else if (hp15State === "needs_override") hp15Modify.textContent = "Not Patched";
		else if (hp15State === "invalid_payload") hp15Modify.textContent = "Invalid Payload";
		else if (hp15State === "not_checked") hp15Modify.textContent = "Not Monitored";
		else hp15Modify.textContent = "Not Present";
		setHp15State(hp15Modify, hp15State);

		const rendererState = data.renderer_config_state || "unknown";
		rendererConfigState.textContent = prettyPatchState(rendererState);
		setRendererState(rendererConfigState, rendererState);

		const glerState = data.gler_state || "unavailable";
		glerConfigState.textContent = glerState === "applied" ? "Applied"
			: glerState === "absent" ? "Not Applied"
			: glerState === "unknown" ? "Unknown" : "Unavailable";
		setGlerState(glerConfigState, glerState);
		gpm7GlerWarning.hidden = !(data.gpm_device_level_state === "applied" && glerState !== "applied");

		const ueiniStatus = data.ueini_state || "unavailable";
		ueiniSection.hidden = ueiniStatus === "unavailable";
		if (ueiniStatus !== "unavailable") {
			ueiniState.textContent = prettyUeiniState(ueiniStatus);
			setUeiniState(ueiniState, ueiniStatus);
			ueiniEnabled.checked = ueiniStatus === "applied";
		}
		gpuCacheState.textContent = selectedPackage ? "Available" : "—";
		gpuCacheResetButton.disabled = busy || !selectedPackage;


        const mumuDetected = data.mumu_detected === "1";
        advancedControl.hidden = !mumuDetected;
        const mandatoryHp15Disabled = data.mandatory_hp15_saved_disabled === "1";
        const mandatoryRendererDisabled = data.mandatory_renderer_saved_disabled === "1";


		// Future stable MuMu hp15: switch this back to device_checks_required === "0".
		const deviceChecksCanBeForced = supported && data.mumu_detected !== "1";
		deviceChecksForceControl.hidden = !deviceChecksCanBeForced;

		const resolutionReady = supported && data.resolution_patch_ready === "1";
		resolutionSection.hidden = !resolutionReady;
		if (resolutionReady) {
			if (data.resolution_state === "applied") resolutionBinaryState.textContent = `Applied (${data.resolution_actual_scale || "?"}%)`;
			else resolutionBinaryState.textContent = prettyPatchState(data.resolution_state);
			setOptionalState(resolutionBinaryState, data.resolution_state);
		}

		const fpsReady = supported && data.fps_patch_ready === "1";
		fpsSection.hidden = !fpsReady;
		if (fpsReady) {
			fpsDescription.textContent = "Locks the game's FPS cap to the selected target. Actual performance can be lower.";
			if (data.fps_state === "applied") fpsBinaryState.textContent = `Applied (${data.fps_actual_target || "?"} FPS)`;
			else fpsBinaryState.textContent = prettyPatchState(data.fps_state);
			setOptionalState(fpsBinaryState, data.fps_state);
		}

		const pixelflowReady = supported && data.pixelflow_patch_ready === "1";
		pixelflowSection.hidden = !pixelflowReady;
		pixelflowPatchEnabled.dataset.unsupported = pixelflowReady ? "0" : "1";
		pixelflowPatchEnabled.disabled = busy || !pixelflowReady;
		pixelflowMode.dataset.unsupported = pixelflowReady ? "0" : "1";
		pixelflowMode.disabled = busy || !pixelflowReady;
		if (pixelflowReady) {
			const labels = { original: "Game default", enabled: "Forced enabled", disabled: "Forced disabled" };
			pixelflowBinaryState.textContent = labels[data.pixelflow_state] || prettyPatchState(data.pixelflow_state);
			setOptionalState(pixelflowBinaryState, ["enabled", "disabled"].includes(data.pixelflow_state) ? "applied" : data.pixelflow_state);
		}

		const gpmDeviceLevelReady = supported && data.gpm_device_level_patch_ready === "1";
		gpmDeviceLevelSection.hidden = !gpmDeviceLevelReady;
		if (gpmDeviceLevelReady) {
			gpmDeviceLevelBinaryState.textContent = prettyPatchState(data.gpm_device_level_state);
			setOptionalState(gpmDeviceLevelBinaryState, data.gpm_device_level_state);
		}

		const graphicLibraryReady = supported && data.graphic_library_patch_ready === "1";
		graphicLibrarySection.hidden = !graphicLibraryReady;
		if (graphicLibraryReady) {
			if (data.graphic_library_state === "opengl") {
				graphicLibraryBinaryState.textContent = "Applied (OpenGL)";
				setOptionalState(graphicLibraryBinaryState, "applied");
			} else if (data.graphic_library_state === "vulkan") {
				graphicLibraryBinaryState.textContent = "Applied (Vulkan)";
				setOptionalState(graphicLibraryBinaryState, "applied");
			} else {
				graphicLibraryBinaryState.textContent = prettyPatchState(data.graphic_library_state);
				setOptionalState(graphicLibraryBinaryState, data.graphic_library_state);
			}
		}

		const crossPlatformReady = supported && data.cross_platform_patch_ready === "1";
		crossPlatformSection.hidden = !crossPlatformReady;
		if (crossPlatformReady) {
			const state = data.cross_platform_state || "unknown";
			if (state === "pc") crossPlatformBinaryState.textContent = "Applied (PC)";
			else if (state === "mobile") crossPlatformBinaryState.textContent = "Applied (Mobile)";
			else if (state === "console") crossPlatformBinaryState.textContent = "Applied (Console)";
			else crossPlatformBinaryState.textContent = prettyPatchState(state);
			setOptionalState(crossPlatformBinaryState, ["pc", "mobile", "console"].includes(state) ? "applied" : state);
		}

		const controllerModeReady = supported && data.controller_mode_patch_ready === "1";
		controllerModeSection.hidden = !controllerModeReady;
		controllerModeEnabled.dataset.unsupported = controllerModeReady ? "0" : "1";
		controllerModeEnabled.disabled = busy || !controllerModeReady;
		if (controllerModeReady) {
			controllerModeBinaryState.textContent = prettyPatchState(data.controller_mode_state);
			if (data.controller_mode_state === "legacy_applied") {
				clearStateClasses(controllerModeBinaryState);
				controllerModeBinaryState.classList.add("state-warn");
			} else setOptionalState(controllerModeBinaryState, data.controller_mode_state);
		}

		const hideUuidReady = supported && data.hide_uuid_patch_ready === "1";
		hideUuidSection.hidden = !hideUuidReady;
		hideUuidEnabled.dataset.unsupported = hideUuidReady ? "0" : "1";
		hideUuidEnabled.disabled = busy || !hideUuidReady;
		if (hideUuidReady) {
			hideUuidBinaryState.textContent = prettyPatchState(data.hide_uuid_state);
			setOptionalState(hideUuidBinaryState, data.hide_uuid_state);
		}

		const gpuDisplayReady = supported && data.gpu_display_patch_ready === "1";
		gpuDisplaySection.hidden = !gpuDisplayReady;
		if (gpuDisplayReady) {
			gpuDisplayBinaryState.textContent = prettyPatchState(data.gpu_display_state);
			setOptionalState(gpuDisplayBinaryState, data.gpu_display_state);
		}

		const extendedWatermarkReady = supported && data.extended_watermark_patch_ready === "1";
		graphicApiDisplaySection.hidden = !extendedWatermarkReady;
		if (extendedWatermarkReady) {
			const watermarkState = data.extended_watermark_state || "unknown";
			if (watermarkState === "api") graphicApiDisplayBinaryState.textContent = "Applied (Graphic API)";
			else if (watermarkState === "platform") graphicApiDisplayBinaryState.textContent = "Applied (Platform)";
			else if (watermarkState === "both") graphicApiDisplayBinaryState.textContent = "Applied (Graphic API + Platform)";
			else if (watermarkState === "legacy_api") graphicApiDisplayBinaryState.textContent = "Applied (Graphic API (Legacy))";
			else graphicApiDisplayBinaryState.textContent = prettyPatchState(watermarkState);
			if (["api", "platform", "both"].includes(watermarkState)) setOptionalState(graphicApiDisplayBinaryState, "applied");
			else if (watermarkState === "legacy_api") { clearStateClasses(graphicApiDisplayBinaryState); graphicApiDisplayBinaryState.classList.add("state-warn"); }
			else setOptionalState(graphicApiDisplayBinaryState, watermarkState);
		}

		if (loadControls) {
			resolutionEnabled.checked = data.resolution_saved_enabled === "1";
			const scale = Number(data.resolution_saved_scale);
			resolutionScale.value = Number.isInteger(scale) && scale >= 10 && scale <= 200 ? String(scale) : String(DEFAULT_RESOLUTION_SCALE);

			fpsEnabled.checked = data.fps_saved_enabled === "1";
			const target = Number(data.fps_saved_target);
			fpsTarget.value = Number.isInteger(target) && target >= MIN_FPS_TARGET && target <= MAX_FPS_TARGET ? String(target) : String(DEFAULT_FPS_TARGET);

			pixelflowPatchEnabled.checked = ["enabled", "disabled"].includes(data.pixelflow_saved_mode);
			const pixelChoice = pixelflowPatchEnabled.checked ? data.pixelflow_saved_mode : data.pixelflow_saved_choice;
			pixelflowMode.value = ["enabled", "disabled"].includes(pixelChoice) ? pixelChoice : DEFAULT_PIXELFLOW_CHOICE;
			gpmDeviceLevelEnabled.checked = data.gpm_device_level_saved_enabled === "1";
			graphicLibraryEnabled.checked = data.graphic_library_saved_enabled === "1";
			graphicLibrary.value = data.graphic_library_saved === "vulkan" ? "vulkan" : DEFAULT_GRAPHIC_LIBRARY;
			crossPlatformEnabled.checked = data.cross_platform_saved_enabled === "1";
			crossPlatform.value = ["pc", "mobile", "console"].includes(data.cross_platform_saved) ? data.cross_platform_saved : DEFAULT_CROSS_PLATFORM;
			gpuDisplayEnabled.checked = data.gpu_display_saved_enabled === "1";
			hideUuidEnabled.checked = data.hide_uuid_saved_enabled === "1";
			controllerModeEnabled.checked = data.controller_mode_saved_enabled === "1";
			graphicApiDisplayEnabled.checked = data.graphic_api_display_saved_enabled === "1";
			platformDisplayEnabled.checked = data.platform_display_saved_enabled === "1";
			forceDeviceChecksEnabled.checked = deviceChecksCanBeForced && data.device_checks_saved_forced === "1";
		}
        if (!sharedDirty) {
			enableHp15.checked = !mandatoryHp15Disabled;
			enableRenderer.checked = !mandatoryRendererDisabled;
			enableHp15Watcher.checked = data.hp15_watcher_saved_disabled !== "1";
			enableRendererWatcher.checked = data.renderer_watcher_saved_disabled !== "1";
			enableGler.checked = data.mandatory_gler_saved_disabled !== "1";
		}

		if (rendererState === "unknown") {
			setStatus("error", "MuMu renderer configuration is unsafe", "renderer.config is unreadable or its tracked backup no longer matches the effective configuration. It won't be modified.");
			return false;
		}
		if (!mandatoryRendererDisabled && rendererState === "needs_patch") {
			setStatus("error", "MuMu compatibility fix is pending", "Use Save or Repair to remove forced GPU spoofing for all declared packages.");
			return false;
		}
		if (mandatoryRendererDisabled && rendererState === "applied") {
			setStatus("error", "Mandatory patch state needs reconciliation", "MuMu Shader Compatibility is configured to stay unpatched. Use Save or Repair to restore the tracked renderer fields.");
			return false;
		}

		if (hp15State === "invalid_payload") {
			setStatus("error", "MuMu libhp15 payload is invalid", "Repair the module installation before launching the game.");
			return false;
		}
		if (!mandatoryHp15Disabled && hp15State === "needs_override") {
			setStatus("error", "MuMu libhp15 override is pending", "Use Save or Repair to retry the shared compatibility override.");
			return false;
		}
		if (mandatoryHp15Disabled && hp15State === "override") {
			setStatus("error", "Mandatory patch state needs reconciliation", "Shared libhp15 is configured to stay unpatched. Use Save or Repair to restore it.");
			return false;
		}

		if (!supported) {
			setStatus("error", "Installed build is not supported", `Version ${data.game_version || "unknown"} has no exact binary profile. Save and Repair remain available for the shared MuMu settings; binary patches require a compatible profile.`);
			return false;
		}

		const mandatoryUnknown = data.mandatory_unknown === "1";
		const optionalUnknown = (controllerModeReady && data.controller_mode_state === "unknown") || (hideUuidReady && data.hide_uuid_state === "unknown") || (pixelflowReady && data.pixelflow_state === "unknown") || (resolutionReady && data.resolution_state === "unknown") || (fpsReady && data.fps_state === "unknown") || (gpmDeviceLevelReady && data.gpm_device_level_state === "unknown") || (graphicLibraryReady && data.graphic_library_state === "unknown") || (crossPlatformReady && data.cross_platform_state === "unknown") || (gpuDisplayReady && data.gpu_display_state === "unknown") || (extendedWatermarkReady && data.extended_watermark_state === "unknown");
		if (mandatoryUnknown || optionalUnknown) {
			setStatus("error", "Binary anomaly detected", "A managed patch location contains unknown bytes. Save is intentionally blocked; use Repair to rebuild the library from the checksum-verified APK before applying the current configuration.");
			return false;
		}

        const mandatoryExpectedApplied = data.device_checks_required === "1" || data.device_checks_saved_forced === "1";
        const mandatoryInactive = mandatoryControls.some(({ index }) => {
            const disabled = mumuDetected && data[`mandatory_patch_${index}_saved_disabled`] === "1";
            const expected = mandatoryExpectedApplied && !disabled ? "applied" : "original";
            return data[`patch_${index}_raw_state`] !== expected;
        });
		if (mandatoryInactive) {
			setStatus("error", "Device-check state needs reconciliation", "Click Save or Repair to reconcile the mandatory patch configuration.");
			return false;
		}

		const resolutionMismatch = resolutionReady && (
			data.resolution_saved_enabled === "1"
				? data.resolution_state !== "applied" || data.resolution_actual_scale !== data.resolution_saved_scale
				: data.resolution_state !== "original"
		);
		const fpsMismatch = fpsReady && (
			data.fps_saved_enabled === "1"
				? data.fps_state !== "applied" || data.fps_actual_target !== data.fps_saved_target
				: data.fps_state !== "original"
		);
		const pixelflowMismatch = pixelflowReady && data.pixelflow_state !== (data.pixelflow_saved_mode || "original");
		const gpmDeviceLevelMismatch = gpmDeviceLevelReady && (
			data.gpm_device_level_saved_enabled === "1"
				? data.gpm_device_level_state !== "applied"
				: data.gpm_device_level_state !== "original"
		);
		const savedGraphicLibrary = data.graphic_library_saved === "vulkan" ? "vulkan" : DEFAULT_GRAPHIC_LIBRARY;
		const graphicLibraryMismatch = graphicLibraryReady && (
			data.graphic_library_saved_enabled === "1"
				? data.graphic_library_state !== savedGraphicLibrary
				: data.graphic_library_state !== "original"
		);
		const savedCrossPlatform = ["pc", "mobile", "console"].includes(data.cross_platform_saved) ? data.cross_platform_saved : DEFAULT_CROSS_PLATFORM;
		const crossPlatformMismatch = crossPlatformReady && (
			data.cross_platform_saved_enabled === "1"
				? data.cross_platform_state !== savedCrossPlatform
				: data.cross_platform_state !== "original"
		);
		const gpuDisplayMismatch = gpuDisplayReady && (
			data.gpu_display_saved_enabled === "1"
				? data.gpu_display_state !== "applied"
				: data.gpu_display_state !== "original"
		);
		const hideUuidMismatch = hideUuidReady && (
			data.hide_uuid_saved_enabled === "1"
				? data.hide_uuid_state !== "applied"
				: data.hide_uuid_state !== "original"
		);
		const controllerModeMismatch = controllerModeReady && (
			data.controller_mode_saved_enabled === "1"
				? data.controller_mode_state !== "applied"
				: data.controller_mode_state !== "original"
		);
		let expectedWatermarkState = "original";
		if (data.graphic_api_display_saved_enabled === "1" && data.platform_display_saved_enabled === "1") expectedWatermarkState = "both";
		else if (data.graphic_api_display_saved_enabled === "1") expectedWatermarkState = "api";
		else if (data.platform_display_saved_enabled === "1") expectedWatermarkState = "platform";
		const extendedWatermarkMismatch = extendedWatermarkReady && data.extended_watermark_state !== expectedWatermarkState;

		if (controllerModeMismatch || hideUuidMismatch || pixelflowMismatch || resolutionMismatch || fpsMismatch || gpmDeviceLevelMismatch || graphicLibraryMismatch || crossPlatformMismatch || gpuDisplayMismatch || extendedWatermarkMismatch) {
			setStatus("error", "Optional patch state needs reconciliation", "One or more optional patches do not match the saved configuration. Click Save or Repair to reconcile them.");
			return false;
		}

        if (data.optional_metadata_invalid === "1") {
            setStatus("error", "Some profile capabilities are invalid", "Declared patches with invalid metadata were disabled. Correct the profile before using those features.");
            return false;
        }

		if (data.hp15_watcher_saved_disabled === "1" || data.renderer_watcher_saved_disabled === "1") setStatus("success", "Managed state recognized", "Disabled compatibility watchers are not inspected automatically; Save or Repair validates them.");
		else setStatus("success", "Managed state recognized", "The compatibility fix and all available patches match their expected states.");
		return true;
	}

	function getDesiredSettings() {
		const scale = Number(resolutionScale.value);
		if (!Number.isInteger(scale) || scale < 10 || scale > 200) {
			throw new Error("Resolution Scale must be between 10% and 200%.");
		}

		const target = Number(fpsTarget.value);
		if (!Number.isInteger(target) || target < MIN_FPS_TARGET || target > MAX_FPS_TARGET) {
			throw new Error("Target FPS must be between 20 and 240.");
		}

		const selectedGraphicLibrary = graphicLibrary.value;
		if (selectedGraphicLibrary !== "opengl" && selectedGraphicLibrary !== "vulkan") {
			throw new Error("Graphic Library must be OpenGL or Vulkan.");
		}

		const selectedCrossPlatform = crossPlatform.value;
		if (!["pc", "mobile", "console"].includes(selectedCrossPlatform)) {
			throw new Error("Cross Platform must be PC, Mobile or Console.");
		}

		if (!["enabled", "disabled"].includes(pixelflowMode.value)) {
			throw new Error("PixelFlow interpolation must be Yes or No.");
		}
		return {
			pixelflowMode: pixelflowPatchEnabled.checked ? pixelflowMode.value : "original",
			pixelflowChoice: pixelflowMode.value,
			resolutionEnabled: resolutionEnabled.checked,
			resolutionScale: scale,
			fpsEnabled: fpsEnabled.checked,
			fpsTarget: target,
			gpmDeviceLevelEnabled: gpmDeviceLevelEnabled.checked,
			graphicLibraryEnabled: graphicLibraryEnabled.checked,
			graphicLibrary: selectedGraphicLibrary,
			crossPlatformEnabled: crossPlatformEnabled.checked,
			crossPlatform: selectedCrossPlatform,
			hideUuidEnabled: hideUuidEnabled.checked,
			controllerModeEnabled: controllerModeEnabled.checked,
			gpuDisplayEnabled: gpuDisplayEnabled.checked,
			graphicApiDisplayEnabled: graphicApiDisplayEnabled.checked,
			platformDisplayEnabled: platformDisplayEnabled.checked,
			deviceChecksForced: forceDeviceChecksEnabled.checked,
			mandatoryHp15Disabled: !enableHp15.checked,
			mandatoryPatch1Disabled: mandatoryControls[0] ? !mandatoryControls[0].control.checked : false,
			mandatoryPatch2Disabled: mandatoryControls[1] ? !mandatoryControls[1].control.checked : false,
			mandatoryRendererDisabled: !enableRenderer.checked,
			hp15WatcherDisabled: !enableHp15Watcher.checked,
			rendererWatcherDisabled: !enableRendererWatcher.checked,
            patchChoices: mandatoryControls.map(p => `${p.id}:${p.control.checked ? "0" : "1"},`).join("")
		};
	}

	function settingsArgs(desired) {
		return [
			desired.resolutionEnabled ? "1" : "0",
			String(desired.resolutionScale),
			desired.fpsEnabled ? "1" : "0",
			String(desired.fpsTarget),
			desired.gpmDeviceLevelEnabled ? "1" : "0",
			desired.gpuDisplayEnabled ? "1" : "0",
			desired.graphicLibraryEnabled ? "1" : "0",
			desired.graphicLibrary,
			desired.deviceChecksForced ? "1" : "0",
			desired.mandatoryHp15Disabled ? "1" : "0",
			desired.mandatoryPatch1Disabled ? "1" : "0",
			desired.mandatoryPatch2Disabled ? "1" : "0",
			desired.mandatoryRendererDisabled ? "1" : "0",
			desired.graphicApiDisplayEnabled ? "1" : "0",
			desired.crossPlatformEnabled ? "1" : "0",
			desired.crossPlatform,
			desired.hp15WatcherDisabled ? "1" : "0",
			desired.rendererWatcherDisabled ? "1" : "0",
			desired.platformDisplayEnabled ? "1" : "0",
			desired.pixelflowMode,
			desired.pixelflowChoice,
			desired.hideUuidEnabled ? "1" : "0",
			desired.controllerModeEnabled ? "1" : "0",
            desired.patchChoices
		];
	}

    function renderMandatory(data, loadControls) {
        const previous = new Map(mandatoryControls.map(p => [p.id, p.control.checked]));
        mandatoryControls = [];
        mandatoryStatusList.replaceChildren();
        mandatoryControlsList.replaceChildren();
        const count = Math.min(16, Math.max(0, Number(data.patch_count) || 0));
        for (let index = 1; index <= count; index++) {
            const id = data[`patch_${index}_id`];
            const name = data[`patch_${index}_name`] || id;
            const row = document.createElement("div"); row.className = "status-row";
            const label = document.createElement("span"); label.textContent = name;
            const state = document.createElement("strong");
            const raw = data[`patch_${index}_state`];
            state.textContent = raw === "applied" && data.device_checks_required !== "1" ? "Forced" : prettyPatchState(raw);
            setMandatoryState(state, state.textContent);
            row.append(label, state); mandatoryStatusList.append(row);
            const toggle = document.createElement("label"); toggle.className = "advanced-toggle";
            const title = document.createElement("span"); title.textContent = name;
            const control = document.createElement("input"); control.type = "checkbox";
            control.checked = !loadControls && previous.has(id) ? previous.get(id) : data[`mandatory_patch_${index}_saved_disabled`] !== "1";
            control.disabled = busy || data.profile_supported !== "1";
            control.dataset.unsupported = data.profile_supported === "1" ? "0" : "1";
            control.addEventListener("change", () => { dirty = true; });
            toggle.append(title, control); mandatoryControlsList.append(toggle);
            mandatoryControls.push({ index, id, control });
        }
    }

    async function refreshStatus(loadControls) {
        const pkg = selectedPackage;
        const generation = ++statusGeneration;
        const text = await runModule(pkg ? ["status", pkg] : ["shared-status"]);
        if (generation !== statusGeneration || selectedPackage !== pkg) return false;
        const data = parseStatus(text);
        if (data.target_package !== pkg) throw new Error("The backend returned a different game. Reload the page.");
        // A common operation can observe an installation update. Never pair its
        // new context token with controls still populated from the previous build.
        const reloadControls = loadControls || Boolean(contextToken && contextToken !== (data.context_token || ""));
        const healthy = applyStatus(data, reloadControls);
        if (reloadControls) dirty = false;
        return healthy;
    }

    async function loadCatalogue() {
        const data = parseStatus(await runModule(["catalog"]));
        const games = [];
        for (let i = 1; i <= Number(data.game_count || 0); i++) {
            games.push({ package: data[`game_${i}_package`], label: data[`game_${i}_label`], version: data[`game_${i}_version`], state: data[`game_${i}_state`], status: data[`game_${i}_profile_status`] });
        }
        const installed = games.filter(g => g.state !== "not_installed");
        // Multiple build profiles for the same package still count as one game.
        gameSelectorSection.hidden = installed.length < 2;
        const active = installed.find(g => g.package === selectedPackage)
            || installed.find(g => g.package === data.selected_package)
            || installed.find(g => g.state === "supported") || installed[0] || games[0];
        gameSelector.replaceChildren();
        for (const game of games) {
            const option = document.createElement("option");
            option.value = game.package;
            const note = game.state === "supported" ? game.status : ({ not_installed: "Not installed", unsupported: "Unsupported build", profile_conflict: "Profile conflict", label_conflict: "Label conflict" }[game.state] || game.state);
            option.textContent = `${game.label || game.package} · ${game.version || "—"} · ${note || "Unspecified"}`;
            option.disabled = game.state === "not_installed";
            gameSelector.append(option);
        }
        selectedPackage = active ? active.package : "";
        gameSelector.value = selectedPackage;
        selectedPackageNote.textContent = selectedPackage;
        if (!active) {
            contextToken = ""; statusLoaded = false;
            for (const button of [saveButton, repairButton, defaultButton]) button.dataset.unsupported = "1";
            setStatus("error", "No game profiles found", "Install a valid profile before patching a game.");
        }
        return games;
    }

    async function changeGame() {
        if (busy) { gameSelector.value = selectedPackage; return; }
        const next = gameSelector.value;
        if (dirty && !window.confirm("Discard unsaved game settings and switch games?")) { gameSelector.value = selectedPackage; return; }
        selectedPackage = next; selectedPackageNote.textContent = next;
        contextToken = ""; statusGeneration++; dirty = false; statusLoaded = false;
        setBusy(true, "status");
        setStatus("", "Loading game…", "Reading the selected installation and its saved settings.");
        try {
            await refreshStatus(true);
            await runModule(["select", next]);
        } catch (error) {
            contextToken = ""; statusLoaded = false;
            for (const button of [saveButton, repairButton, defaultButton]) button.dataset.unsupported = "1";
            setStatus("error", "Game could not be loaded", error.message);
        } finally { setBusy(false, "status"); }
    }

    function sharedSettingsArgs() {
        return [enableHp15.checked ? "0" : "1", enableHp15Watcher.checked ? "0" : "1", enableRenderer.checked ? "0" : "1", enableRendererWatcher.checked ? "0" : "1", enableGler.checked ? "0" : "1"];
    }

    async function applySettings(mode) {
        if (busy || !statusLoaded) return;
        const binary = Boolean(contextToken && selectedPackage && lastData && lastData.profile_supported === "1" && lastData.target_package === selectedPackage);
        let args;
        try {
            args = binary ? [mode, selectedPackage, contextToken, ...settingsArgs(getDesiredSettings())] : [mode, "--shared", ...sharedSettingsArgs()];
        } catch (error) { setStatus("error", "Invalid settings", error.message); return; }
        setBusy(true, mode);
        setStatus("", mode === "repair" ? "Repair in progress…" : "Saving configuration…", binary ? "Applying shared MuMu settings and the selected game's configuration." : "Applying shared MuMu compatibility settings.");
        await allowPaint();
        try {
            await runModule(args);
            sharedDirty = false;
            const healthy = await refreshStatus(true);
            if (!binary) setStatus("success", "MuMu settings applied", "Shared compatibility settings and watcher choices were saved. No game binary was changed.");
            else if (healthy) setStatus("success", mode === "repair" ? "Repair completed" : "Configuration saved", "Shared MuMu settings and the selected game's configuration were applied successfully.");
        } catch (error) {
            try { await refreshStatus(true); } catch (_) {}
            setStatus("error", mode === "repair" ? "Repair did not complete" : "Save did not complete", error.message);
        } finally { setBusy(false, mode); }
    }

    async function saveSettings(event) {
        event.preventDefault();
        await applySettings("save");
    }

    function loadDefaults() {
        if (busy || !contextToken) return;
        const d = profileDefaults;
        const checks = { resolution_enabled: resolutionEnabled, fps_enabled: fpsEnabled, gpm_device_level_enabled: gpmDeviceLevelEnabled, graphic_library_enabled: graphicLibraryEnabled, cross_platform_enabled: crossPlatformEnabled, gpu_display_enabled: gpuDisplayEnabled, hide_uuid_enabled: hideUuidEnabled, controller_mode_enabled: controllerModeEnabled, graphic_api_display_enabled: graphicApiDisplayEnabled, platform_display_enabled: platformDisplayEnabled, device_checks_forced: forceDeviceChecksEnabled };
        for (const [key, control] of Object.entries(checks)) control.checked = d[key] === "1";
        resolutionScale.value = d.resolution_scale || "100";
        fpsTarget.value = d.fps_target || "60";
        graphicLibrary.value = d.graphic_library || "opengl";
        crossPlatform.value = d.cross_platform || "mobile";
        pixelflowPatchEnabled.checked = ["enabled", "disabled"].includes(d.pixelflow_mode);
        pixelflowMode.value = pixelflowPatchEnabled.checked ? d.pixelflow_mode : (d.pixelflow_choice || "disabled");
        for (const patch of mandatoryControls) patch.control.checked = lastData[`advanced_patch_${patch.index}_default_enabled`] !== "0";
        dirty = true;
        setStatus("", "Defaults loaded", "The selected game's defaults are ready. Press Save or Repair to apply them.");
    }

    async function repairBinary() { await applySettings("repair"); }

	form.addEventListener("submit", saveSettings);
    gameSelector.addEventListener("change", changeGame);
    for (const control of managedControls) {
        if (![gameSelector, enableHp15, enableHp15Watcher, enableRenderer, enableRendererWatcher, enableGler, defaultButton, repairButton, saveButton].includes(control)) control.addEventListener("change", () => { dirty = true; });
    }
    for (const control of [enableHp15, enableHp15Watcher, enableRenderer, enableRendererWatcher, enableGler]) control.addEventListener("change", () => { sharedDirty = true; });
	ueiniEnabled.addEventListener("change", async () => {
		if (busy || !selectedPackage) return;
		const want = ueiniEnabled.checked;
		setBusy(true, "ueini");
		try {
			await runModule(["ueini", selectedPackage, want ? "on" : "off"]);
			setStatus("success", want ? "Streaming fix enabled" : "Streaming fix disabled", want
				? "A marker block was added to this game's Android Engine.ini."
				: "The marker block was removed from this game's Android Engine.ini.");
		} catch (error) {
			ueiniEnabled.checked = !want;
			setStatus("error", "Streaming fix could not be applied", error.message);
		} finally {
			setBusy(false, "ueini");
			try { await refreshStatus(true); } catch (_) {}
		}
	});
	gpuCacheResetButton.addEventListener("click", async () => {
		if (busy || !selectedPackage) return;
		if (!window.confirm(`Reset ${selectedPackage}'s cached GPU identity (shared_prefs/apm_cfg.xml)? One backup is kept in the module state.`)) return;
		setBusy(true, "gpu-cache-reset");
		try {
			const data = parseStatus(await runModule(["gpu-cache-reset", selectedPackage]));
			if (data.gpu_cache_reset === "removed") setStatus("success", "GPU cache reset", "The game will re-detect the current MuMu GPU on its next launch.");
			else setStatus("", "Nothing to reset", "No cached GPU identity was found for this game.");
		} catch (error) {
			setStatus("error", "Reset did not complete", error.message);
		} finally {
			setBusy(false, "gpu-cache-reset");
			try { await refreshStatus(true); } catch (_) {}
		}
	});
	defaultButton.addEventListener("click", loadDefaults);
	repairButton.addEventListener("click", repairBinary);

	resolutionEnabled.checked = DEFAULT_RESOLUTION_ENABLED;
	resolutionScale.value = String(DEFAULT_RESOLUTION_SCALE);
	fpsEnabled.checked = DEFAULT_FPS_ENABLED;
	fpsTarget.value = String(DEFAULT_FPS_TARGET);
	pixelflowPatchEnabled.checked = DEFAULT_PIXELFLOW_PATCH_ENABLED;
	pixelflowMode.value = DEFAULT_PIXELFLOW_CHOICE;
	gpmDeviceLevelEnabled.checked = DEFAULT_GPM_DEVICE_LEVEL_ENABLED;
	graphicLibraryEnabled.checked = DEFAULT_GRAPHIC_LIBRARY_ENABLED;
	graphicLibrary.value = DEFAULT_GRAPHIC_LIBRARY;
	crossPlatformEnabled.checked = DEFAULT_CROSS_PLATFORM_ENABLED;
	crossPlatform.value = DEFAULT_CROSS_PLATFORM;
	gpuDisplayEnabled.checked = DEFAULT_GPU_DISPLAY_ENABLED;
	hideUuidEnabled.checked = DEFAULT_HIDE_UUID_ENABLED;
	controllerModeEnabled.checked = DEFAULT_CONTROLLER_MODE_ENABLED;
	graphicApiDisplayEnabled.checked = DEFAULT_GRAPHIC_API_DISPLAY_ENABLED;
	platformDisplayEnabled.checked = DEFAULT_PLATFORM_DISPLAY_ENABLED;
	forceDeviceChecksEnabled.checked = DEFAULT_DEVICE_CHECKS_FORCED;
	enableHp15.checked = advancedDefaults.hp15;
	enableRenderer.checked = advancedDefaults.renderer;
	enableHp15Watcher.checked = advancedDefaults.hp15_watcher;
	enableRendererWatcher.checked = advancedDefaults.renderer_watcher;
	enableGler.checked = true;

	setBusy(true, "status");
	setStatus("", "Reading module status…", "Checking MuMu compatibility, the installed game build and managed binary locations.");
	allowPaint()
		.then(() => loadCatalogue()).then(() => refreshStatus(true))
		.catch((error) => setStatus("error", "Status could not be read", error.message))
		.finally(() => setBusy(false, "status"));
})();
