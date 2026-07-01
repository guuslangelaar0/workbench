(function () {
  "use strict";

  var state = {
    token: "",
    events: [],
    actors: [],
    devices: [],
    lastSeq: 0,
    socket: null
  };

  var els = {};

  document.addEventListener("DOMContentLoaded", function () {
    bindElements();
    hydrateToken();
    bindControls();
    render();
    loadState();
  });

  function bindElements() {
    els.tokenForm = document.getElementById("token-form");
    els.tokenInput = document.getElementById("token-input");
    els.connection = document.getElementById("connection-state");
    els.seq = document.getElementById("seq-state");
    els.room = document.getElementById("room-input");
    els.actor = document.getElementById("actor-input");
    els.target = document.getElementById("target-input");
    els.message = document.getElementById("message-input");
    els.availability = document.getElementById("availability-input");
    els.inviteRole = document.getElementById("invite-role");
    els.device = document.getElementById("device-input");
    els.task = document.getElementById("task-input");
    els.assignee = document.getElementById("assignee-input");
    els.inviteOutput = document.getElementById("invite-output");
    els.devicesBody = document.getElementById("devices-body");
    els.toast = document.getElementById("toast");
    els.eventList = document.getElementById("event-list");
    els.auditList = document.getElementById("audit-list");
    els.leadMatrix = document.getElementById("lead-matrix");
    els.roomsGrid = document.getElementById("rooms-grid");
    els.workersBody = document.getElementById("workers-body");
    els.jobsBody = document.getElementById("jobs-body");
    els.tasksBody = document.getElementById("tasks-body");
    els.decisionsBody = document.getElementById("decisions-body");
  }

  function hydrateToken() {
    var params = new URLSearchParams(window.location.search);
    var queryToken = params.get("token");
    state.token = queryToken || window.localStorage.getItem("meshCommandToken") || "";
    els.tokenInput.value = state.token;
    if (state.token) {
      window.localStorage.setItem("meshCommandToken", state.token);
    }
  }

  function bindControls() {
    els.tokenForm.addEventListener("submit", function (event) {
      event.preventDefault();
      state.token = els.tokenInput.value.trim();
      if (state.token) {
        window.localStorage.setItem("meshCommandToken", state.token);
      }
      loadState();
    });

    document.querySelectorAll("[data-action]").forEach(function (button) {
      button.addEventListener("click", function () {
        runAction(button.getAttribute("data-action"));
      });
    });

    document.getElementById("refresh-button").addEventListener("click", loadState);
  }

  function headers(json) {
    var result = {};
    if (state.token) {
      result.Authorization = "Bearer " + state.token;
    }
    if (json) {
      result["Content-Type"] = "application/json";
    }
    return result;
  }

  function loadState() {
    if (!state.token) {
      setConnection("Token needed", "warn");
      return Promise.resolve();
    }
    return fetch("/api/state", { headers: headers(false) })
      .then(requireOk)
      .then(function (data) {
        state.events = Array.isArray(data.events) ? data.events : [];
        state.actors = Array.isArray(data.actors) ? data.actors : [];
        state.devices = Array.isArray(data.devices) ? data.devices : [];
        state.lastSeq = Number(data.last_seq || 0);
        setConnection("API online", "ok");
        render();
        connectSocket();
      })
      .catch(function (error) {
        setConnection("API denied", "bad");
        showToast(error.message);
      });
  }

  function connectSocket() {
    if (!state.token || state.socket) {
      return;
    }
    var protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
    var url = protocol + "//" + window.location.host + "/ws?token=" + encodeURIComponent(state.token) + "&last_seq=" + state.lastSeq;
    state.socket = new WebSocket(url);
    state.socket.addEventListener("open", function () {
      setConnection("WS live", "ok");
    });
    state.socket.addEventListener("message", function (event) {
      var payload = safeJson(event.data);
      if (!payload || payload.type === "ack") {
        return;
      }
      upsertEvent(payload);
      render();
    });
    state.socket.addEventListener("close", function () {
      state.socket = null;
      if (state.token) {
        setConnection("WS closed", "warn");
      }
    });
    state.socket.addEventListener("error", function () {
      setConnection("WS error", "bad");
    });
  }

  function runAction(action) {
    var base = commandBase();
    var message = els.message.value.trim() || "status?";
    var target = els.target.value.trim();

    if (action === "create-invite") {
      createInvite();
      return;
    }

    var event = null;
    if (action === "send-message") {
      event = makeEvent("message.sent", base, target, { text: message });
    } else if (action === "ask-status") {
      event = makeEvent("message.request_status", base, target, { text: "status requested" });
    } else if (action === "request-help") {
      event = makeEvent("message.help_request", base, target, { text: message, priority: "operator" });
    } else if (action === "revoke-invite") {
      revokeInvite(message);
      return;
    } else if (action === "revoke-device") {
      revokeDevice(els.device.value.trim() || message);
      return;
    } else if (action === "approve-decision") {
      event = makeEvent("decision.answer", base, target, { decision: message, answer: "approved", approved: true });
    } else if (action === "deny-decision") {
      event = makeEvent("decision.answer", base, target, { decision: message, answer: "denied", approved: false });
    } else if (action === "reassign-task") {
      event = makeEvent("task.reassigned", base, target, { task: els.task.value.trim() || message, assignee: els.assignee.value.trim() || target || "unassigned" });
    } else if (action === "stop-job") {
      event = makeEvent("job.cancelled", base, target, { job: message, reason: "operator stopped" });
    } else if (action === "retry-job") {
      event = makeEvent("job.queued", base, target, { job: message, retry: true });
    } else if (action === "adopt-lead") {
      event = makeEvent("lead.adopted", base, target, { lead: target || message, reason: "stale lead adopted" });
    } else if (action === "close-lead") {
      event = makeEvent("lead.closed", base, target, { lead: target || message, reason: "operator closed" });
    } else if (action === "set-availability") {
      event = makeEvent("actor.status", base, target, { intent: "availability.set", availability: els.availability.value });
    }

    if (event) {
      postEvent(event);
    }
  }

  function commandBase() {
    return {
      room: els.room.value.trim() || "repo:workbench",
      from: els.actor.value.trim() || "ui:owner"
    };
  }

  function makeEvent(type, base, target, payload) {
    var event = {
      type: type,
      room: base.room,
      from: base.from,
      payload: payload
    };
    if (target) {
      event.to = target;
    }
    return event;
  }

  function postEvent(event) {
    if (!state.token) {
      showToast("Set a bearer token first.");
      return;
    }
    fetch("/api/events", {
      method: "POST",
      headers: headers(true),
      body: JSON.stringify(event)
    })
      .then(requireOk)
      .then(function (data) {
        upsertEvent(data);
        render();
        showToast("Recorded " + data.type + " at seq " + data.seq + ".");
      })
      .catch(function (error) {
        showToast(error.message);
      });
  }

  function createInvite() {
    if (!state.token) {
      showToast("Set a bearer token first.");
      return;
    }
    fetch("/api/invites", {
      method: "POST",
      headers: headers(true),
      body: JSON.stringify({
        role: els.inviteRole.value,
        ttl_seconds: 3600,
        max_uses: 1
      })
    })
      .then(requireOk)
      .then(function (data) {
        var base = "http://" + window.location.host;
        els.inviteOutput.textContent = [
          "token=" + data.token,
          "role=" + data.role,
          "expires_at=" + data.expires_at,
          "connect=/workbench:mesh connect " + base + " " + data.token + " <device>"
        ].join("\n");
        showToast("Created invite for " + data.role + ".");
        return postEvent(makeEvent("invite.created", commandBase(), "", { role: data.role, expires_at: data.expires_at, source: "command-center" }));
      })
      .catch(function (error) {
        showToast(error.message);
      });
  }

  function revokeInvite(token) {
    if (!state.token) {
      showToast("Set a bearer token first.");
      return;
    }
    if (!token) {
      showToast("Paste an invite token to revoke.");
      return;
    }
    fetch("/api/invites/revoke", {
      method: "POST",
      headers: headers(true),
      body: JSON.stringify({ token: token })
    })
      .then(requireOk)
      .then(function () {
        showToast("Revoked invite.");
        return postEvent(makeEvent("invite.revoked", commandBase(), "", { token_hint: tokenHint(token), reason: "operator revoked" }));
      })
      .catch(function (error) {
        showToast(error.message);
      });
  }

  function revokeDevice(device) {
    if (!state.token) {
      showToast("Set a bearer token first.");
      return;
    }
    if (!device) {
      showToast("Enter a device to revoke.");
      return;
    }
    fetch("/api/devices/revoke", {
      method: "POST",
      headers: headers(true),
      body: JSON.stringify({ device: device })
    })
      .then(requireOk)
      .then(function () {
        showToast("Revoked device.");
        return loadState();
      })
      .catch(function (error) {
        showToast(error.message);
      });
  }

  function tokenHint(token) {
    return token.length <= 12 ? token : token.slice(0, 12) + "...";
  }

  function upsertEvent(event) {
    if (!event || !event.seq) {
      return;
    }
    var existing = state.events.findIndex(function (item) {
      return item.seq === event.seq;
    });
    if (existing >= 0) {
      state.events[existing] = event;
    } else {
      state.events.push(event);
    }
    state.events.sort(function (a, b) {
      return a.seq - b.seq;
    });
    state.lastSeq = Math.max(state.lastSeq, event.seq);
    [event.from, event.to].forEach(function (actor) {
      if (actor && state.actors.indexOf(actor) === -1) {
        state.actors.push(actor);
      }
    });
  }

  function render() {
    els.seq.textContent = "seq " + state.lastSeq;
    var rooms = unique(state.events.map(function (event) { return event.room; }));
    var open = state.events.filter(function (event) {
      return /request|queued|started|failed|stale|help|claim/.test(event.type || "");
    }).length;
    text("count-events", state.events.length);
    text("count-actors", state.actors.length);
    text("count-rooms", rooms.length);
    text("count-open", open);
    renderRail();
    renderLeads();
    renderWorkers();
    renderRooms(rooms);
    renderJobs();
    renderTasks();
    renderDecisions();
    renderDevices();
    renderAudit();
  }

  function renderRail() {
    var latest = state.events.slice(-40).reverse();
    els.eventList.innerHTML = latest.length ? latest.map(function (event) {
      return "<li><span class=\"seq\">#" + event.seq + "</span><span><span class=\"event-type\">" + escapeHtml(event.type) + "</span><span class=\"event-meta\">" + escapeHtml(event.room) + " / " + escapeHtml(event.from) + "</span></span></li>";
    }).join("") : "<li><span class=\"seq\">#0</span><span class=\"event-meta\">No events recorded</span></li>";
  }

  function renderLeads() {
    var leadEvents = state.events.filter(function (event) {
      return event.type && event.type.indexOf("lead.") === 0;
    }).slice(-8);
    els.leadMatrix.innerHTML = leadEvents.length ? leadEvents.map(function (event) {
      return "<div class=\"matrix-cell\"><strong>" + escapeHtml(event.from) + "</strong><span>" + escapeHtml(event.type) + " in " + escapeHtml(event.room) + "</span></div>";
    }).join("") : "<div class=\"empty\">No lead events.</div>";
  }

  function renderWorkers() {
    var actorRows = state.actors.map(function (actor) {
      var last = lastForActor(actor);
      return "<tr><td>" + escapeHtml(actor) + "</td><td>" + escapeHtml(last.room || "-") + "</td><td>" + chip(signalFor(last)) + "</td><td>" + escapeHtml(shortTime(last.ts)) + "</td></tr>";
    });
    els.workersBody.innerHTML = actorRows.length ? actorRows.join("") : row(4, "No workers observed.");
  }

  function renderRooms(rooms) {
    els.roomsGrid.innerHTML = rooms.length ? rooms.map(function (room) {
      var count = state.events.filter(function (event) { return event.room === room; }).length;
      var latest = lastForRoom(room);
      return "<div class=\"room-cell\"><strong>" + escapeHtml(room) + "</strong><span>" + count + " events / " + escapeHtml(latest.type || "idle") + "</span></div>";
    }).join("") : "<div class=\"empty\">No rooms observed.</div>";
  }

  function renderJobs() {
    var jobs = state.events.filter(function (event) {
      return event.type && event.type.indexOf("job.") === 0;
    }).slice(-12).reverse();
    els.jobsBody.innerHTML = jobs.length ? jobs.map(function (event) {
      return "<tr><td>" + escapeHtml(event.payload && (event.payload.job || event.payload.name) || event.id) + "</td><td>" + escapeHtml(event.room) + "</td><td>" + chip(event.type.replace("job.", "")) + "</td><td>" + escapeHtml(event.from) + "</td></tr>";
    }).join("") : row(4, "No jobs observed.");
  }

  function renderTasks() {
    var tasks = state.events.filter(function (event) {
      return event.type && event.type.indexOf("task.") === 0;
    }).slice(-12).reverse();
    els.tasksBody.innerHTML = tasks.length ? tasks.map(function (event) {
      return "<tr><td>" + escapeHtml(event.payload && event.payload.task || event.id) + "</td><td>" + escapeHtml(event.payload && event.payload.assignee || event.to || "-") + "</td><td>" + chip(event.type.replace("task.", "")) + "</td><td>" + escapeHtml(event.room) + "</td></tr>";
    }).join("") : row(4, "No tasks observed.");
  }

  function renderDecisions() {
    var decisions = state.events.filter(function (event) {
      return event.type && event.type.indexOf("decision.") === 0;
    }).slice(-12).reverse();
    els.decisionsBody.innerHTML = decisions.length ? decisions.map(function (event) {
      return "<tr><td>" + escapeHtml(event.payload && event.payload.decision || event.id) + "</td><td>" + escapeHtml(event.room) + "</td><td>" + chip(event.payload && event.payload.answer || event.type.replace("decision.", "")) + "</td><td>" + escapeHtml(event.from) + "</td></tr>";
    }).join("") : row(4, "No decisions observed.");
  }

  function renderDevices() {
    var rows = state.devices.map(function (device) {
      var revoked = device.revoked_at ? "revoked" : "active";
      return "<tr><td>" + escapeHtml(device.device || "-") + "</td><td>" + escapeHtml(device.role || "-") + "</td><td>" + escapeHtml(shortTime(device.accepted_at)) + "</td><td>" + escapeHtml(shortTime(device.last_seen_at)) + "</td><td>" + chip(revoked) + "</td></tr>";
    });
    els.devicesBody.innerHTML = rows.length ? rows.join("") : row(5, "No devices connected.");
  }

  function renderAudit() {
    var audit = state.events.filter(function (event) {
      return /invite|device|decision|lead|task|job|status/.test(event.type || "");
    }).slice(-12).reverse();
    els.auditList.innerHTML = audit.length ? audit.map(function (event) {
      return "<li><strong>" + escapeHtml(event.type) + "</strong><div class=\"event-meta\">" + escapeHtml(event.from) + " / " + escapeHtml(shortTime(event.ts)) + "</div></li>";
    }).join("") : "<li class=\"empty\">No audit-grade events.</li>";
  }

  function chip(value) {
    var label = String(value || "unknown");
    var klass = /done|available|approved|online/.test(label) ? "status-ok" : /fail|blocked|denied|cancel|closed/.test(label) ? "status-bad" : "status-warn";
    return "<span class=\"status-chip " + klass + "\">" + escapeHtml(label) + "</span>";
  }

  function lastForActor(actor) {
    for (var i = state.events.length - 1; i >= 0; i -= 1) {
      if (state.events[i].from === actor || state.events[i].to === actor) {
        return state.events[i];
      }
    }
    return {};
  }

  function lastForRoom(room) {
    for (var i = state.events.length - 1; i >= 0; i -= 1) {
      if (state.events[i].room === room) {
        return state.events[i];
      }
    }
    return {};
  }

  function signalFor(event) {
    if (event.payload && event.payload.availability) {
      return event.payload.availability;
    }
    if (event.type) {
      return event.type.replace(/^.*\./, "");
    }
    return "unknown";
  }

  function requireOk(response) {
    return response.text().then(function (textBody) {
      var body = safeJson(textBody) || {};
      if (!response.ok) {
        throw new Error(body.error || response.status + " " + response.statusText);
      }
      return body;
    });
  }

  function setConnection(label, kind) {
    els.connection.textContent = label;
    els.connection.className = "status-chip status-" + kind;
  }

  function showToast(message) {
    els.toast.textContent = message;
    els.toast.classList.add("show");
    window.clearTimeout(showToast.timer);
    showToast.timer = window.setTimeout(function () {
      els.toast.classList.remove("show");
    }, 3200);
  }

  function text(id, value) {
    document.getElementById(id).textContent = value;
  }

  function row(cols, message) {
    return "<tr><td colspan=\"" + cols + "\" class=\"empty\">" + escapeHtml(message) + "</td></tr>";
  }

  function unique(values) {
    return values.filter(Boolean).filter(function (value, index, list) {
      return list.indexOf(value) === index;
    });
  }

  function safeJson(textValue) {
    try {
      return JSON.parse(textValue);
    } catch (error) {
      return null;
    }
  }

  function shortTime(value) {
    if (!value) {
      return "-";
    }
    return String(value).replace("T", " ").replace(/\..*$/, "Z");
  }

  function escapeHtml(value) {
    return String(value == null ? "" : value).replace(/[&<>"']/g, function (char) {
      return {
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        "\"": "&quot;",
        "'": "&#39;"
      }[char];
    });
  }
}());
