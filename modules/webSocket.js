import { makeApiRequest, getSessionInfo, isAuthReadyStrict, waitForAuthReadyStrict, persistAuthSnapshotFromApiClient } from "./api.js";
import { getServerAddress as _getServerAddress } from "./config.js";

window.currentMediaSourceId = null;
window.currentPlayingSessionId = null;
window.currentPlayingItemId = null;

let attached = false;
let playbackWebSocket = null;
let lastPlaybackSignalAt = 0;
let backoffMs = 1000;

const timers = {
  reattach: null,
  sessionsInterval: null,
  fastPollBatch: new Set(),
  videoCleanup: null,
  staleWatch: null,
};

const BACKOFF_MIN = 1000;
const BACKOFF_MAX = 15000;
const FAST_POLL_SCHEDULE = [150, 600, 1500, 5000, 9000];
const SESSIONS_POLL_MS_VISIBLE = 30000;
const SESSIONS_POLL_MS_HIDDEN = 120000;
const STALE_CLEAR_MS = 20000;

window.webSocketMonitor = {
  enabled: false,
  logs: [],
  maxLogs: 1000,
  connectionStatus: 'connecting',
  lastMessageTime: null,
  messageCount: 0
};

function persistDeviceAndSession() {
  try {
    const info = getSessionInfo?.() || {};
    const devId = getCurrentDeviceId?.() || info.deviceId;
    if (devId) localStorage.setItem("persist_device_id", devId);
    if (info.userId) localStorage.setItem("persist_user_id", info.userId);
  } catch {}
}

function restoreDeviceAndSession() {
  try {
    const devId = localStorage.getItem("persist_device_id");
    const userId = localStorage.getItem("persist_user_id");
    if (devId) {
      localStorage.setItem("deviceId", devId);
      try { localStorage.setItem("jf_api_deviceId", devId); } catch {}
    }
    if (userId) {
      localStorage.setItem("persist_user_id_hint", userId);
    }
  } catch {}
}

function isLoopbackOrLocal(host) {
  if (!host) return false;
  const raw = String(host).trim();
  const h = raw.replace(/^\[|\]$/g, "").toLowerCase();
  const is127 = /^127(?:\.\d{1,3}){3}$/.test(h);

  return (
    h === "localhost" ||
    h === "::1" ||
    is127 ||
    h.endsWith(".local")
  );
}

function getHostnameCandidatesForEnvCheck() {
  const hosts = [];
  try {
    if (window.location?.hostname) hosts.push(window.location.hostname);
  } catch {}

  try {
    const sa = safeGetServerAddress?.();
    if (sa) {
      try {
        hosts.push(new URL(sa).hostname);
      } catch {
        try {
          hosts.push(new URL(/^https?:\/\//i.test(sa) ? sa : `http://${sa}`).hostname);
        } catch {
          const m = String(sa).match(/^\[?([^\]\/:]+)\]?/);
          if (m && m[1]) hosts.push(m[1]);
        }
      }
    }
  } catch {}

  return hosts.filter(Boolean);
}

function isDevEnvironment() {
  const hosts = getHostnameCandidatesForEnvCheck();
  const isLocalHostMatch = hosts.some(isLoopbackOrLocal);

  return (
    isLocalHostMatch ||
    window.location.search.includes("debug=true") ||
    (typeof Storage !== "undefined" &&
      localStorage.getItem("debugMode") === "true")
  );
}

function clearTimer(refName) {
  const id = timers[refName];
  if (id) clearTimeout(id), clearInterval(id);
  timers[refName] = null;
}

function safeGetServerAddress() {
  try {
    const sa = _getServerAddress?.();
    if (sa) return sa;
  } catch {}
  try {
    const api = window.ApiClient;
    if (api && typeof api.serverAddress === "function") {
      const v = api.serverAddress();
      if (v) return v;
    }
  } catch {}
  return null;
}

function tryReadApiClientDeviceId() {
  try {
    const api = window.ApiClient;
    if (!api) return null;
    const candidates = [
      api.deviceId,
      api._deviceId,
      api.deviceInfo?.id,
      api._appInfo?.deviceId,
    ].filter(Boolean);
    return candidates[0] || null;
  } catch {
    return null;
  }
}

function tryReadStoredDeviceId() {
  try {
    const keys = [
      "deviceId",
      "apiClientDeviceId",
      "jellyfin_device_id",
      "jellyfinweb_device_id",
    ];
    for (const k of keys) {
      const v = localStorage.getItem(k);
      if (v) return v;
    }
  } catch {}
  return null;
}

function getCurrentDeviceId() {
  try {
    const s = getSessionInfo?.() || {};
    return (
      s.deviceId ||
      tryReadStoredDeviceId() ||
      tryReadApiClientDeviceId() ||
      null
    );
  } catch {
    return null;
  }
}

function getApiClientWebSocket() {
  try {
    const api = window.ApiClient;
    if (!api) return null;
    return (
      api._webSocket ||
      api._socket ||
      api.websocket ||
      (api.connectionManager && api.connectionManager._webSocket) ||
      null
    );
  } catch {
    return null;
  }
}

function isOpen(sock) {
  return sock && sock.readyState === 1;
}

function markPlaybackSignal() {
  lastPlaybackSignalAt = Date.now();
}

function clearPlaybackState(reason = "stale_or_manual") {
  if (
    window.currentMediaSourceId ||
    window.currentPlayingSessionId ||
    window.currentPlayingItemId
  ) {
    if (isDevEnvironment()) {
      console.log("[WS] Playback state cleaning:", reason);
    }
  }
  window.currentMediaSourceId = null;
  window.currentPlayingSessionId = null;
  window.currentPlayingItemId = null;
  try {
    window.dispatchEvent(new CustomEvent("mediaplaybackstop", { detail: { reason } }));
  } catch {}
}

function detachListeners() {
  try {
    if (playbackWebSocket) {
      playbackWebSocket.removeEventListener?.("message", onMessage);
      playbackWebSocket.removeEventListener?.("open", onOpen);
      playbackWebSocket.removeEventListener?.("close", onClose);
      playbackWebSocket.removeEventListener?.("error", onError);
    }
  } catch {}
  playbackWebSocket = null;
  attached = false;
}

function scheduleReattach() {
  clearTimer("reattach");
  const delay = backoffMs;
  timers.reattach = setTimeout(() => {
    attachToExistingWebSocket();
  }, delay);
  backoffMs = Math.min(backoffMs * 2, BACKOFF_MAX);
}

function resetBackoff() {
  backoffMs = BACKOFF_MIN;
}

function attachToExistingWebSocket() {
  const sock = getApiClientWebSocket();

  if (!sock) {
    scheduleReattach();
    return;
  }

  if (attached && playbackWebSocket === sock && isOpen(sock)) return;

  detachListeners();
  playbackWebSocket = sock;

  try {
    playbackWebSocket.addEventListener("message", onMessage);
    playbackWebSocket.addEventListener("open", onOpen, { once: false });
    playbackWebSocket.addEventListener("close", onClose, { once: false });
    playbackWebSocket.addEventListener("error", onError, { once: false });

    attached = true;
    resetBackoff();
    scheduleFastSessionChecks(true);
    ensureSessionsPolling();
    ensureStaleWatchDog();
    if (window.webSocketMonitor.enabled) {
      addMonitorLog('CONNECTION', 'ApiClient WebSocket listener added', {
        readyState: sock.readyState,
        url: sock.url || 'unknown'
      });
    }
  } catch (e) {
    console.warn("WS attach error:", e);
    attached = false;
    scheduleReattach();

    if (window.webSocketMonitor.enabled) {
      addMonitorLog('ERROR', 'WebSocket connection error', { error: e.message });
    }
  }
}

function cancelFastPollBatch() {
  for (const t of timers.fastPollBatch) clearTimeout(t);
  timers.fastPollBatch.clear();
}

function scheduleFastSessionChecks(runNow = false) {
  cancelFastPollBatch();
  if (runNow) checkActiveSessionsForMediaSourceId();
  if (document.hidden) return;

  for (const ms of FAST_POLL_SCHEDULE) {
    const id = setTimeout(() => {
      timers.fastPollBatch.delete(id);
      checkActiveSessionsForMediaSourceId();
    }, ms);
    timers.fastPollBatch.add(id);
  }
}

function ensureSessionsPolling() {
  if (timers.sessionsInterval) return;
  const intervalMs = document.hidden
    ? SESSIONS_POLL_MS_HIDDEN
    : SESSIONS_POLL_MS_VISIBLE;

  timers.sessionsInterval = setInterval(() => {
    checkActiveSessionsForMediaSourceId();
  }, intervalMs);
}

function refreshSessionsPollingInterval() {
  if (!timers.sessionsInterval) return;
  clearTimer("sessionsInterval");
  timers.sessionsInterval = null;
  ensureSessionsPolling();
}

async function coldRehydrateAuthThenAttach() {
  const t0 = Date.now();
  const max = 15000;
  while (!window.ApiClient && Date.now() - t0 < max) {
    await new Promise(r => setTimeout(r, 300));
  }
  try { persistAuthSnapshotFromApiClient(); } catch {}
  attachToExistingWebSocket();
}

function onOpen() {
  console.log("[WS] ApiClient socket extra listener attached.");
  resetBackoff();
  scheduleFastSessionChecks(true);
  clearTimer("videoCleanup");
  try { persistAuthSnapshotFromApiClient(); } catch {}
  persistDeviceAndSession();
  try { persistAuthSnapshotFromApiClient(); } catch {}

  if (window.webSocketMonitor.enabled) {
    addMonitorLog('CONNECTION', 'WebSocket connection opened');
    window.webSocketMonitor.connectionStatus = 'connected';
  }
}

function onClose(evt) {
  console.log("[WS] ApiClient socket closed:", evt?.code, evt?.reason || "");
  attached = false;
  scheduleReattach();

  if (window.webSocketMonitor.enabled) {
    addMonitorLog('CONNECTION', 'WebSocket connection closed', {
      code: evt?.code,
      reason: evt?.reason
    });
    window.webSocketMonitor.connectionStatus = 'disconnected';
  }
}

function onError(err) {
  if (isDevEnvironment()) {
    console.warn("[WS] Error:", err);
  }

  if (window.webSocketMonitor.enabled) {
    addMonitorLog('ERROR', 'WebSocket error', { error: err.message });
  }
}

function onMessage(event) {
  let payload = null;
  try {
    payload = JSON.parse(event.data);
  } catch {
    return;
  }

  if (window.webSocketMonitor.enabled) {
    window.webSocketMonitor.lastMessageTime = new Date();
    window.webSocketMonitor.messageCount++;
    addMonitorLog('MESSAGE', 'WebSocket message received', {
      messageType: payload.MessageType,
      data: payload.Data ? 'Available' : 'None'
    });
  }

  handleWebSocketMessage(payload);
}

function handleWebSocketMessage(data) {
  if (!data || !data.MessageType) return;

  const currentDeviceId = getCurrentDeviceId();
  const msgDevId = data.Data?.DeviceId || data.Data?.Session?.DeviceId;
  const isSelf = msgDevId && currentDeviceId && msgDevId === currentDeviceId;

  switch (data.MessageType) {
    case "PlaybackStart":
      handlePlaybackStart(data, { isSelf });
      break;
    case "PlaybackStop":
      handlePlaybackStop(data, { isSelf });
      break;
    case "PlaybackProgress":
      handlePlaybackProgress(data, { isSelf });
      break;
    case "SessionKeepAlive":
      break;
    default:
      if (data.Data) checkForMediaSourceId(data.Data, { isSelf });
      break;
  }
}

function handlePlaybackStart(data, { isSelf }) {
  const s = data.Data || {};
  const item = s.NowPlayingItem || s.Item;
  if (!item) return;

  const mediaSourceId =
    s.PlayState?.MediaSourceId || item.MediaSourceId || null;
  if (!mediaSourceId) return;

  clearTimer("videoCleanup");

  if (isSelf) {
    window.currentMediaSourceId = mediaSourceId;
    window.currentPlayingSessionId = s.Id || s.SessionId || null;
    window.currentPlayingItemId = item.Id || null;
    markPlaybackSignal();
  }

  if (isDevEnvironment()) {
    console.log("Playback started:", {
      mediaSourceId,
      sessionId: s.Id || s.SessionId || null,
      itemId: item.Id || null,
      deviceId: s.DeviceId,
      itemName: item.Name,
      isSelf,
    });
  }

  if (window.webSocketMonitor.enabled) {
    addMonitorLog('PLAYBACK', 'Playback started', {
      mediaSourceId,
      itemName: item.Name,
      isSelf,
      deviceId: s.DeviceId
    });
  }

  if (isSelf) {
    window.dispatchEvent(
      new CustomEvent("mediaplaybackstart", {
        detail: {
          mediaSourceId: window.currentMediaSourceId,
          sessionId: window.currentPlayingSessionId,
          itemId: window.currentPlayingItemId,
          deviceId: s.DeviceId,
          itemName: item.Name,
        },
      })
    );
  }
}

function handlePlaybackProgress(data, { isSelf }) {
  if (!isSelf) return;
  const s = data.Data || {};
  if (s.PlayState?.MediaSourceId) {
    window.currentMediaSourceId = s.PlayState.MediaSourceId;
    window.currentPlayingSessionId =
      s.Id || s.SessionId || window.currentPlayingSessionId;
  }
  clearTimer("videoCleanup");
  markPlaybackSignal();

  if (window.webSocketMonitor.enabled) {
    addMonitorLog('PLAYBACK', 'Playback progress', {
      mediaSourceId: window.currentMediaSourceId,
      position: s.PlayState?.PositionTicks
    });
  }
}

function isVideoItem(item) {
  const t = (item?.MediaType || item?.Type || "").toLowerCase();
  return t === "video" || item?.IsVideo === true;
}

function didPlaybackFinish(s) {
  if (s?.PlayedToCompletion === true) return true;
  if (s?.Ended === true) return true;
  if ((s?.Reason || "").toLowerCase() === "playbackended") return true;
  const rt = s?.Item?.RunTimeTicks || s?.RunTimeTicks || 0;
  const pos = s?.PlayState?.PositionTicks || s?.PositionTicks || 0;
  if (rt && pos && Math.abs(rt - pos) <= 20_000_000) return true;
  return false;
}

function scheduleFullCleanupAfterVideoEnd() {
  clearTimer("videoCleanup");
  timers.videoCleanup = setTimeout(() => {
    if (isDevEnvironment()) {
      console.log("🎬 Video ended: full cleanup ran after 20 sec.");
    }
    fullCleanup();
  }, 20_000);
}

function fullCleanup() {
  window.currentMediaSourceId = null;
  window.currentPlayingSessionId = null;
  window.currentPlayingItemId = null;
  clearTimer("reattach");
  clearTimer("sessionsInterval");
  cancelFastPollBatch();
  clearTimer("videoCleanup");
  detachListeners();

  try {
    window.removeEventListener("ApiClientReady", onApiClientReady);
    document.removeEventListener("visibilitychange", onVisibilityChange);
    window.removeEventListener("jf-media-source-id", onJfMediaSourceId);
    window.removeEventListener("beforeunload", onBeforeUnload);
  } catch {}

  if (isDevEnvironment()) {
    console.log("✅ Full cleanup completed.");
  }
}

function handlePlaybackStop(data, { isSelf }) {
  const s = data.Data || {};
  if (isDevEnvironment()) {
    console.log("Playback stopped:", s.Item?.Name, { isSelf });
  }

  if (window.webSocketMonitor.enabled) {
    addMonitorLog('PLAYBACK', 'Playback stopped', {
      itemName: s.Item?.Name,
      isSelf,
      reason: s.Reason
    });
  }

  if (isSelf) {
    markPlaybackSignal();
    if (isVideoItem(s.Item) && didPlaybackFinish(s)) {
      scheduleFullCleanupAfterVideoEnd();
    } else {
      clearTimer("videoCleanup");
    }
  }
}

function checkForMediaSourceId(d, { isSelf }) {
  const mediaSourceId =
    d.MediaSourceId || d.PlayState?.MediaSourceId || d.NowPlayingItem?.MediaSourceId;

  if (isSelf && mediaSourceId && mediaSourceId !== window.currentMediaSourceId) {
    window.currentMediaSourceId = mediaSourceId;
    if (isDevEnvironment()) {
      console.log("🔍 MediaSourceId caught:", mediaSourceId, "DeviceId:", d.DeviceId || "(none)");
    }
    markPlaybackSignal();

    if (window.webSocketMonitor.enabled) {
      addMonitorLog('MEDIA_SOURCE', 'MediaSourceId updated', {
        mediaSourceId,
        deviceId: d.DeviceId
      });
    }
  }
}

async function checkActiveSessionsForMediaSourceId() {
  try {
    try {
      if (typeof isAuthReadyStrict === "function" && !isAuthReadyStrict()) {
        if (typeof waitForAuthReadyStrict === "function") {
          await waitForAuthReadyStrict(3000);
        }
      }
    } catch {}
    const deviceId = getCurrentDeviceId();
    if (!deviceId) {
      if (isDevEnvironment()) {
        console.warn("DeviceId not found, session check skipped");
      }
      return;
    }

    const sessions = await makeApiRequest("/Sessions");
    if (!Array.isArray(sessions)) return;
    let matching = sessions.filter((s) => s?.DeviceId === deviceId);
    if (matching.length === 0) {
      const userId = (getSessionInfo?.() || {}).userId || null;
      matching = sessions.filter((s) => {
        if (userId && s?.UserId && s.UserId !== userId) return false;
        const client = (s?.Client || "").toLowerCase();
        return client.includes("web") || client.includes("browser");
      });
    }

    if (matching.length === 0) {
      if (isDevEnvironment()) {
        console.log("No active session found with this DeviceId:", deviceId);
      }
      return;
    }

    for (const s of matching) {
      const item = s.NowPlayingItem;
      if (item && s.PlayState?.MediaSourceId) {
        window.currentMediaSourceId = s.PlayState.MediaSourceId;
        window.currentPlayingSessionId = s.Id;
        window.currentPlayingItemId = item.Id;

        if (isDevEnvironment()) {
          console.log("Active session found:", {
            mediaSourceId: window.currentMediaSourceId,
            sessionId: window.currentPlayingSessionId,
            deviceId: s.DeviceId,
            item: item.Name,
          });
        }
        markPlaybackSignal();

        if (window.webSocketMonitor.enabled) {
          addMonitorLog('SESSION', 'Active session found', {
            mediaSourceId: window.currentMediaSourceId,
            sessionId: window.currentPlayingSessionId,
            itemName: item.Name
          });
        }
        break;
      }
    }
  } catch (e) {
    if (isDevEnvironment()) {
      console.error("Session check error:", e);
    }

    if (window.webSocketMonitor.enabled) {
      addMonitorLog('ERROR', 'Session check error', { error: e.message });
    }
  }
}

function ensureStaleWatchDog() {
  if (timers.staleWatch) return;
  timers.staleWatch = setInterval(async () => {
    if (
      !window.currentMediaSourceId &&
      !window.currentPlayingSessionId &&
      !window.currentPlayingItemId
    ) {
      return;
    }

    const elapsed = Date.now() - (lastPlaybackSignalAt || 0);
    const budget = document.hidden ? STALE_CLEAR_MS * 2 : STALE_CLEAR_MS;
    if (elapsed > budget) {
      if (isDevEnvironment()) {
        console.log("[WS] Stale watch: timeout exceeded, verifying session…", { elapsed, budget });
      }
      try {
        await checkActiveSessionsForMediaSourceId();
      } catch {}

      if ((Date.now() - (lastPlaybackSignalAt || 0)) > budget) {
        clearPlaybackState("stale_timeout");

        if (window.webSocketMonitor.enabled) {
          addMonitorLog('CLEANUP', 'Playback state cleared (timeout)');
        }
      }
    }
  }, 5000);
}

function addMonitorLog(type, message, data = null) {
  const logEntry = {
    timestamp: new Date().toISOString(),
    type,
    message,
    data,
    playbackState: {
      mediaSourceId: window.currentMediaSourceId,
      sessionId: window.currentPlayingSessionId,
      itemId: window.currentPlayingItemId
    }
  };

  window.webSocketMonitor.logs.unshift(logEntry);
  if (window.webSocketMonitor.logs.length > window.webSocketMonitor.maxLogs) {
    window.webSocketMonitor.logs = window.webSocketMonitor.logs.slice(0, window.webSocketMonitor.maxLogs);
  }
}

function getMonitorStats() {
  return {
    enabled: window.webSocketMonitor.enabled,
    connectionStatus: window.webSocketMonitor.connectionStatus,
    totalMessages: window.webSocketMonitor.messageCount,
    lastMessageTime: window.webSocketMonitor.lastMessageTime,
    currentPlayback: getCurrentPlaybackInfo(),
    logCount: window.webSocketMonitor.logs.length,
    attached,
    playbackWebSocketReadyState: playbackWebSocket?.readyState || 'none'
  };
}

function clearMonitorLogs() {
  window.webSocketMonitor.logs = [];
  window.webSocketMonitor.messageCount = 0;
}

export function manualWebSocketTest() {
  console.log('=== MANUAL WEBSOCKET TEST STARTING ===');

  const testResults = {
    startTime: new Date().toISOString(),
    tests: [],
    overallStatus: 'success'
  };
  try {
    const apiClient = window.ApiClient;
    if (!apiClient) {
      throw new Error('ApiClient not found');
    }
    testResults.tests.push({ name: 'ApiClient Check', status: 'success' });
  } catch (error) {
    testResults.tests.push({ name: 'ApiClient Check', status: 'failed', error: error.message });
    testResults.overallStatus = 'failed';
  }

  try {
    const ws = getApiClientWebSocket();
    if (!ws) {
      throw new Error('WebSocket not found');
    }
    testResults.tests.push({
      name: 'WebSocket Check',
      status: 'success',
      details: {
        readyState: ws.readyState,
        url: ws.url || 'unknown'
      }
    });
  } catch (error) {
    testResults.tests.push({ name: 'WebSocket Check', status: 'failed', error: error.message });
    testResults.overallStatus = 'failed';
  }

  try {
    const deviceId = getCurrentDeviceId();
    if (!deviceId) {
      throw new Error('DeviceId not found');
    }
    testResults.tests.push({
      name: 'DeviceId Check',
      status: 'success',
      details: { deviceId }
    });
  } catch (error) {
    testResults.tests.push({ name: 'DeviceId Check', status: 'failed', error: error.message });
    testResults.overallStatus = 'failed';
  }

  try {
    const sessionInfo = getSessionInfo();
    testResults.tests.push({
      name: 'Session Info',
      status: 'success',
      details: sessionInfo
    });
  } catch (error) {
    testResults.tests.push({ name: 'Session Info', status: 'failed', error: error.message });
  }

  try {
    const playbackInfo = getCurrentPlaybackInfo();
    testResults.tests.push({
      name: 'Playback State',
      status: 'success',
      details: playbackInfo
    });
  } catch (error) {
    testResults.tests.push({ name: 'Playback State', status: 'failed', error: error.message });
  }

  try {
    const timerStatus = {};
    Object.keys(timers).forEach(key => {
      timerStatus[key] = timers[key] ? 'active' : 'inactive';
    });
    testResults.tests.push({
      name: 'Timer Statuses',
      status: 'success',
      details: timerStatus
    });
  } catch (error) {
    testResults.tests.push({ name: 'Timer Statuses', status: 'failed', error: error.message });
  }

  console.log('🧪 WEBSOCKET TEST RESULTS:');
  console.log('Overall Status:', testResults.overallStatus);
  testResults.tests.forEach(test => {
    console.log(`📊 ${test.name}:`, test.status);
    if (test.error) {
      console.log(`   ❌ Error:`, test.error);
    }
    if (test.details) {
      console.log(`   ℹ️  Details:`, test.details);
    }
  });
  if (window.webSocketMonitor.enabled) {
    addMonitorLog('TEST', 'Manual WebSocket test completed', testResults);
  }

  return testResults;
}

export function startWebSocketMonitor() {
  console.log('🔍 WEBSOCKET MONITOR STARTING...');

  window.webSocketMonitor.enabled = true;
  window.webSocketMonitor.startTime = new Date();
  window.webSocketMonitor.connectionStatus = 'monitoring';

  addMonitorLog('MONITOR', 'WebSocket monitor started');

  const statusInterval = setInterval(() => {
    if (!window.webSocketMonitor.enabled) {
      clearInterval(statusInterval);
      return;
    }

    const stats = getMonitorStats();
    addMonitorLog('STATUS', 'System status report', stats);

  }, 30000);

  window.stopWebSocketMonitor = function() {
    console.log('🔍 WEBSOCKET MONITOR STOPPING...');
    window.webSocketMonitor.enabled = false;
    clearInterval(statusInterval);
    addMonitorLog('MONITOR', 'WebSocket monitor stopped');
  };

  console.log('✅ WebSocket Monitor active. To stop: stopWebSocketMonitor()');
  console.log('📊 To see monitor stats: getMonitorStats()');
  console.log('🗑️  To clear logs: clearMonitorLogs()');

  return {
    stop: window.stopWebSocketMonitor,
    getStats: getMonitorStats,
    clearLogs: clearMonitorLogs,
    getLogs: () => window.webSocketMonitor.logs
  };
}

export function getCurrentMediaSourceId() {
  return window.currentMediaSourceId;
}

export function getCurrentPlaybackInfo() {
  return {
    mediaSourceId: window.currentMediaSourceId,
    sessionId: window.currentPlayingSessionId,
    itemId: window.currentPlayingItemId,
    deviceId: getCurrentDeviceId(),
  };
}

export function restartWebSocketConnection() {
  setTimeout(() => {
    attachToExistingWebSocket();
    scheduleFastSessionChecks(true);
  }, 100);
}

export function logDeviceInfo() {
  const deviceId = getCurrentDeviceId();
  console.log("Current DeviceId:", deviceId);
  return deviceId;
}

function onVisibilityChange() {
  if (!document.hidden) {
    scheduleFastSessionChecks(true);
  }
  refreshSessionsPollingInterval();
}

function onApiClientReady() {
  try { persistAuthSnapshotFromApiClient(); } catch {}
  attachToExistingWebSocket();
}

function onBeforeUnload() {
  clearTimer("reattach");
  clearTimer("sessionsInterval");
  cancelFastPollBatch();
  clearTimer("videoCleanup");
  if (timers.staleWatch) {
    clearInterval(timers.staleWatch);
    timers.staleWatch = null;
  }
  detachListeners();
  window.removeEventListener("ApiClientReady", onApiClientReady);
  document.removeEventListener("visibilitychange", onVisibilityChange);
  window.removeEventListener("jf-media-source-id", onJfMediaSourceId);
  window.removeEventListener("beforeunload", onBeforeUnload);
}

function onJfMediaSourceId(e) {
  const { mediaSourceId, itemId } = e.detail || {};
  const myDev = getCurrentDeviceId();
  if (mediaSourceId && myDev) {
    window.currentMediaSourceId = mediaSourceId;
    window.currentPlayingItemId =
      itemId || window.currentPlayingItemId;
    if (isDevEnvironment()) {
      console.log("Quick MediaSourceId (event):", mediaSourceId);
    }

    if (window.webSocketMonitor.enabled) {
      addMonitorLog('MEDIA_SOURCE', 'MediaSourceId updated via event', {
        mediaSourceId,
        itemId
      });
    }
  }
}

function boot() {
  restoreDeviceAndSession();
  window.addEventListener("ApiClientReady", onApiClientReady, { once: false });
  document.addEventListener("visibilitychange", onVisibilityChange, { passive: true });
  window.addEventListener("jf-media-source-id", onJfMediaSourceId);
  window.addEventListener("beforeunload", onBeforeUnload, { once: true });
  const start = () => {
    coldRehydrateAuthThenAttach().finally(() => {
      scheduleFastSessionChecks(true);
      ensureSessionsPolling();
      ensureStaleWatchDog();
    });
  };
  if ("requestIdleCallback" in window) {
    window.requestIdleCallback(start, { timeout: 1200 });
  } else {
    setTimeout(start, 0);
  }
}

window.manualWebSocketTest = manualWebSocketTest;
window.startWebSocketMonitor = startWebSocketMonitor;
window.getMonitorStats = getMonitorStats;
window.clearMonitorLogs = clearMonitorLogs;

if (typeof window !== "undefined") {
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => boot(), { once: true });
  } else {
    boot();
  }
}
