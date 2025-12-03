const JSON_PREFIX = "Stored JSON credentials:";
const WS_PREFIX   = "opening web socket with url:";

export function saveCredentials(credentials) {
  try {
    const raw = JSON.stringify(credentials);
    sessionStorage.setItem("json-credentials", raw);
    localStorage.setItem("json-credentials", raw);

    if (credentials?.AccessToken) {
      sessionStorage.setItem("accessToken", credentials.AccessToken);
      localStorage.setItem("accessToken", credentials.AccessToken);
    }

    const serverId =
      credentials?.ServerId ||
      credentials?.SystemId ||
      credentials?.DeviceId === 'Server' ? null : null ||
      credentials?.Servers?.[0]?.SystemId ||
      credentials?.Servers?.[0]?.Id ||
      (() => {
        try {
          const ac = window.ApiClient || window.apiClient || null;
          return ac?._serverInfo?.SystemId || ac?._serverInfo?.Id || null;
        } catch { return null; }
      })();

    if (serverId) {
      sessionStorage.setItem("serverId", serverId);
      localStorage.setItem("serverId", serverId);
    }

    console.log("Kimlik bilgileri kaydedildi.");
  } catch (err) {
    console.error("Kimlik bilgileri kaydedilirken hata:", err);
  }
}


export function getWebClientHints() {
  const hints = {};
  try {
    const ac = window.ApiClient || window.apiClient || null;
    if (ac) {
      hints.sessionId =
        ac._sessionId || ac.sessionId || ac?.connectionManager?._session?.Id || null;
      hints.deviceId =
        ac._deviceId || (typeof ac.deviceId === "function" ? ac.deviceId() : ac.deviceId) || null;
      hints.accessToken =
        ac._authToken || ac.accessToken || ac?._serverInfo?.AccessToken || null;
      hints.clientName = ac._appName || ac.name || "Jellyfin Web";
      hints.clientVersion = ac._appVersion || ac.appVersion || "1.0.0";
      hints.serverId =
        ac?._serverInfo?.SystemId ||
        ac?._serverInfo?.Id ||
        null;
    }
  } catch {}

  try {
    const lsDeviceId =
      localStorage.getItem("deviceId") ||
      localStorage.getItem("emby.device.id") ||
      null;
    if (!hints.deviceId && lsDeviceId) hints.deviceId = lsDeviceId;

    const lsSessionId =
      localStorage.getItem("sessionId") ||
      localStorage.getItem("emby.session.id") ||
      null;
    if (!hints.sessionId && lsSessionId) hints.sessionId = lsSessionId;
    const lsServerId =
      localStorage.getItem("serverId") ||
      localStorage.getItem("emby.server.id") ||
      null;
    if (!hints.serverId && lsServerId) hints.serverId = lsServerId;
  } catch {}

  return hints;
}

export function saveApiKey(apiKey) {
  try {
    sessionStorage.setItem("api-key", apiKey);
    localStorage.setItem("api-key", apiKey);
    sessionStorage.setItem("accessToken", apiKey);
    localStorage.setItem("accessToken", apiKey);
    try {
      const ac = window.ApiClient || window.apiClient || null;
      const serverId = ac?._serverInfo?.SystemId || ac?._serverInfo?.Id || null;
      if (serverId) {
        sessionStorage.setItem("serverId", serverId);
        localStorage.setItem("serverId", serverId);
      }
    } catch {}

    console.log("API anahtarı kaydedildi.");
  } catch (err) {
    console.error("API anahtarı kaydedilirken hata:", err);
  }
}


function clearCredentials() {
  ["json-credentials","api-key","accessToken","serverId"].forEach(k => {
    sessionStorage.removeItem(k);
    localStorage.removeItem(k);
  });
  console.log("Tüm kimlik bilgileri temizlendi.");
}

export function getAuthToken() {
  return (
    sessionStorage.getItem("api-key") ||
    localStorage.getItem("api-key") ||
    sessionStorage.getItem("accessToken") ||
    localStorage.getItem("accessToken") ||
    new URLSearchParams(window.location.search).get("api_key") ||
    (window.ApiClient && window.ApiClient._authToken) ||
    null
  );
}

(function interceptConsoleLog() {
  const orig = console.log;
  console.log = function(...args) {
    args.forEach(arg => {
      if (typeof arg === "string" && arg.startsWith(JSON_PREFIX)) {
        try {
          const cred = JSON.parse(arg.slice(JSON_PREFIX.length).trim());
          clearCredentials();
          saveCredentials(cred);
        } catch {}
      }
      else if (arg && typeof arg === "object" && arg.AccessToken && arg.SessionId && arg.User) {
        clearCredentials();
        saveCredentials(arg);
      }
      if (typeof arg === "string" && arg.startsWith(WS_PREFIX)) {
        const url = arg.split("url:")[1]?.trim();
        if (url) {
          try {
            const key = new URL(url).searchParams.get("api_key");
            if (key) saveApiKey(key);
            try {
              const ac = window.ApiClient || window.apiClient || null;
              const serverId = ac?._serverInfo?.SystemId || ac?._serverInfo?.Id || null;
              if (serverId) {
                sessionStorage.setItem("serverId", serverId);
                localStorage.setItem("serverId", serverId);
              }
            } catch {}
          } catch {}
        }
      }
    });
    orig.apply(console, args);
  };
})();


async function onLoginSubmit(credentials) {
  const response = await authenticateUser(username, password);
  saveCredentials(response);
  saveApiKey(response.AccessToken);
  initApp();
}

export {
  clearCredentials,
};
