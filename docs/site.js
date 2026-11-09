/* Notch Agents site.
   The island on this page is not a recording. AgentStore below is a port of
   Sources/NotchAgents/AgentStore.swift, and it is fed hook events of the same
   shape Claude Code sends. In the desktop scene the events are a scripted
   sample and scroll is the clock; further down, the visitor sends them. */
(function () {
  'use strict';

  var $ = function (s, r) { return (r || document).querySelector(s); };
  var $$ = function (s, r) { return Array.prototype.slice.call((r || document).querySelectorAll(s)); };
  var clamp = function (x, a, b) { a = a === undefined ? 0 : a; b = b === undefined ? 1 : b; return x < a ? a : x > b ? b : x; };
  var ramp = function (x, a, b) { return clamp((x - a) / (b - a)); };
  var smooth = function (x) { x = clamp(x); return x * x * (3 - 2 * x); };
  var esc = function (s) { return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); };
  var base = function (p) { return String(p).replace(/\/+$/, '').split('/').pop(); };
  var fmt = function (t) { var s = Math.max(0, Math.floor(t)); return s < 60 ? s + 's' : Math.floor(s / 60) + 'm ' + (s % 60) + 's'; };
  var reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  var finePointer = matchMedia('(hover: hover) and (pointer: fine)').matches;
  var root = document.documentElement;

  /* =================================================================== STORE
     Port of AgentStore.swift. Time is passed in, so the same store runs on the
     scroll clock in the desktop scene and on the wall clock below it. */
  var PROMPT_TIMEOUT = 25, QUESTION_TIMEOUT = 600, LINGER = 8;

  function describe(e) {
    var tool = e.tool_name || 'tool', i = e.tool_input || {};
    var d = i.file_path || i.command || i.pattern || i.description;
    if (typeof d !== 'string') return tool;
    if (d.charAt(0) === '/') d = base(d);
    if (d.length > 40) d = d.slice(0, 40) + '…';
    return tool + ' ' + d;
  }
  function fullDetail(e) {
    var i = e.tool_input || {}, keys = ['command', 'file_path', 'url', 'pattern', 'path', 'query', 'prompt'];
    for (var k = 0; k < keys.length; k++) if (typeof i[keys[k]] === 'string') return i[keys[k]];
    var all = Object.keys(i);
    return all.length ? all.sort().map(function (k) { return k + ': ' + JSON.stringify(i[k]); }).join('\n') : (e.tool_name || 'tool');
  }
  function decisionJSON(allow) {
    var decision = allow ? { behavior: 'allow' } : { behavior: 'deny', message: 'The user denied this from Notch Agents.' };
    return JSON.stringify({ hookSpecificOutput: { decision: decision, hookEventName: 'PermissionRequest' } });
  }

  function AgentStore() { this.agents = []; this.pending = []; this.lastMessage = null; this.seq = 0; }
  AgentStore.prototype = {
    running: function () { return this.agents.filter(function (a) { return a.state === 'running'; }); },
    isVisible: function () { return this.agents.length > 0 || this.pending.length > 0; },
    find: function (key) { for (var i = 0; i < this.agents.length; i++) if (this.agents[i].id === key) return this.agents[i]; return null; },
    upsert: function (key, type, project, now) {
      var a = this.find(key);
      if (a) { a.type = type; if (a.state === 'done') { a.state = 'running'; a.endedAt = null; } }
      else this.agents.push({ id: key, type: type, project: project, currentTool: null, state: 'running', startedAt: now, endedAt: null });
    },
    finish: function (key, now) {
      var a = this.find(key);
      if (!a || a.state !== 'running') return;
      a.state = 'done'; a.currentTool = null; a.endedAt = now;
    },
    dropPending: function (match) {
      this.pending = this.pending.filter(function (p) { if (match(p)) { p.responder(null); return false; } return true; });
    },
    handle: function (e, now, responder) {
      var name = e.hook_event_name || '';
      var session = e.session_id || '?';
      var key = session + ':' + (e.agent_id || 'main');
      var project = e.cwd ? base(e.cwd) : 'session';
      var type = e.agent_id == null ? (e.session_title || project) : (e.agent_type || 'agent');
      var a;
      switch (name) {
        case 'SubagentStart': this.upsert(key, type, project, now); break;
        case 'SubagentStop': this.finish(key, now); break;
        case 'PreToolUse':
          this.upsert(key, type, project, now);
          a = this.find(key); if (a) a.currentTool = describe(e);
          break;
        case 'PostToolUse':
          a = this.find(key); if (a) a.currentTool = null;
          // The tool ran, so any island prompt for it was answered elsewhere.
          this.dropPending(function (p) { return p.agentKey === key && p.tool === (e.tool_name || ''); });
          break;
        case 'PermissionRequest':
          if (!responder) break;
          this.upsert(key, type, project, now);
          var isQuestion = e.tool_name === 'AskUserQuestion';
          if (isQuestion) responder(null);
          a = this.find(key); if (a) a.currentTool = isQuestion ? 'Asking you a question' : 'Waiting for approval';
          this.pending.push({ id: ++this.seq, session: session, agentKey: key, title: type, tool: e.tool_name || 'tool',
            detail: fullDetail(e), isQuestion: isQuestion, createdAt: now, responder: responder });
          break;
        case 'Stop':
          this.finish(session + ':main', now);
          this.dropPending(function (p) { return p.session === session; });
          break;
        case 'Notification': this.lastMessage = e.message; break;
        default: break;   // SessionStart: nothing to draw yet
      }
    },
    decide: function (id, allow) {
      for (var i = 0; i < this.pending.length; i++) {
        if (this.pending[i].id !== id) continue;
        var p = this.pending.splice(i, 1)[0];
        p.responder(decisionJSON(allow));
        var a = this.find(p.agentKey);
        if (a) a.currentTool = (allow ? 'Approved ' : 'Denied ') + p.tool;
        return;
      }
    },
    // Time-based housekeeping: unanswered prompts fall back to the terminal,
    // finished agents are tidied away a few seconds after they end.
    sweep: function (now) {
      this.dropPending(function (p) { return now - p.createdAt >= (p.isQuestion ? QUESTION_TIMEOUT : PROMPT_TIMEOUT); });
      this.agents = this.agents.filter(function (a) { return !(a.state === 'done' && now - a.endedAt >= LINGER); });
    }
  };

  /* ============================================================= ISLAND VIEW */
  var island = $('#island'), islInd = $('#islInd'), islCount = $('#islCount'), islBody = $('#islBody');
  var islRows = $('#islRows'), islCard = $('#islCard'), islLeft = $('#islLeft'), islSub = $('#islSub'), islCmd = $('#islCmd');
  var islAllow = $('#islAllow'), islDeny = $('#islDeny'), islFoot = $('.isl-card__ft', islCard);
  var SPIN = '<svg class="spin" viewBox="0 0 16 16">' + [0, 1, 2, 3, 4, 5, 6, 7].map(function (i) {
    return '<rect x="7.2" y="1.2" width="1.6" height="4.2" rx="0.8" fill="currentColor" opacity="' + (0.22 + 0.78 * i / 7).toFixed(2) + '" transform="rotate(' + i * 45 + ' 8 8)"/>';
  }).join('') + '</svg>';
  var CHECK = '<svg viewBox="0 0 16 16"><circle cx="8" cy="8" r="7" fill="#30d158"/><path d="m4.8 8.3 2.2 2.2 4.2-4.7" fill="none" stroke="#000" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  var rowEls = {}, indKind = '', shownPrompt = null, hovering = false;

  function text(el, s) { if (el.textContent !== s) el.textContent = s; }

  function drawIsland(store, now, show, expandedWanted) {
    var prompt = null;
    for (var i = 0; i < store.pending.length; i++) if (!store.pending[i].isQuestion) { prompt = store.pending[i]; break; }
    if (!prompt) prompt = store.pending[0] || null;
    var visible = show && store.isVisible();
    // A pending permission request keeps the island open until it is answered.
    var expanded = visible && (expandedWanted || hovering || !!prompt);
    var state = !visible ? 'hidden' : expanded ? 'expanded' : 'collapsed';

    var running = store.running().length;
    var kind = running ? 'spin' : 'check';
    if (kind !== indKind) { islInd.innerHTML = running ? SPIN : CHECK; indKind = kind; }
    text(islCount, running ? running + ' active' : 'Done');

    // rows, keyed so a new one eases in and the rest stay put
    var seen = {}, prev = null;
    store.agents.forEach(function (a) {
      var li = rowEls[a.id];
      if (!li) {
        li = document.createElement('li'); li.className = 'isl-row';
        li.innerHTML = '<span class="isl-dot"></span><span class="isl-t"><b></b><small></small></span><span class="isl-time"></span>';
        li._b = li.querySelector('b'); li._s = li.querySelector('small'); li._t = li.querySelector('.isl-time');
        rowEls[a.id] = li;
      }
      var want = prev ? prev.nextSibling : islRows.firstChild;
      if (li !== want) islRows.insertBefore(li, want);
      text(li._b, a.type);
      text(li._s, a.project + ' · ' + (a.currentTool || (a.state === 'running' ? 'thinking…' : 'finished')));
      text(li._t, fmt((a.endedAt == null ? now : a.endedAt) - a.startedAt));
      li.classList.toggle('done', a.state === 'done');
      prev = li; seen[a.id] = 1;
    });
    Object.keys(rowEls).forEach(function (id) { if (!seen[id]) { rowEls[id].remove(); delete rowEls[id]; } });

    if (prompt) {
      text(islSub, prompt.title + ' · ' + prompt.tool);
      text(islCmd, prompt.detail);
      text(islLeft, Math.max(0, Math.floor(PROMPT_TIMEOUT - (now - prompt.createdAt))) + 's');
      var more = store.pending.length - 1;
      text(islFoot, more > 0 ? '+' + more + ' more waiting · no answer = ask in terminal' : 'No answer = Claude asks in the terminal');
    }
    if (!!prompt === islCard.hidden) islCard.hidden = !prompt;
    shownPrompt = prompt;

    if (island.dataset.state !== state) { island.dataset.state = state; document.body.classList.toggle('isl-on', state !== 'hidden'); }
    var h = islBody.offsetHeight;
    if (island._h !== h) { island._h = h; island.style.setProperty('--h', h + 'px'); }
  }

  island.addEventListener('mouseenter', function () { if (finePointer) { hovering = true; dirty = true; } });
  island.addEventListener('mouseleave', function () { if (finePointer) { hovering = false; dirty = true; } });
  island.addEventListener('click', function (e) {
    if (finePointer || e.target.closest('button')) return;
    hovering = !hovering; dirty = true;            // touch: tap the pill to open it
  });
  islAllow.addEventListener('click', function () { answer(true); });
  islDeny.addEventListener('click', function () { answer(false); });

  /* =========================================================== THE SCENARIO
     Four Claude Code sessions, as the hook events they would emit. `t` is
     seconds on the scene clock. Keys starting with _ are for the terminals
     drawn on this page and are not part of a real payload. */
  var SESS = {
    s1: { session_id: 's1', cwd: '/Users/you/code/api', session_title: 'Refactor auth module', dir: '~/code/api', open: 0, prompt: 'Refactor the auth module and keep the tests green' },
    s2: { session_id: 's2', cwd: '/Users/you/code/website', session_title: 'Rewrite install guide', dir: '~/code/website', open: 36, prompt: 'Rewrite the install guide for 0.2.0' },
    s3: { session_id: 's3', cwd: '/Users/you/code/mobile', session_title: 'Checkout crash on launch', dir: '~/code/mobile', open: 74, prompt: 'Find why checkout crashes on launch' },
    s4: { session_id: 's4', cwd: '/Users/you/code/infra', session_title: 'Sessions table migration', dir: '~/code/infra', open: 110, prompt: 'Write the migration for the sessions table' }
  };
  var FILM = [];
  function ev(t, s, name, extra) {
    var e = { t: t, _s: s, hook_event_name: name, session_id: SESS[s].session_id, cwd: SESS[s].cwd, session_title: SESS[s].session_title };
    for (var k in extra) e[k] = extra[k];
    FILM.push(e); return e;
  }
  function input(s, tool, arg) {
    if (tool === 'Bash') return { command: arg };
    if (tool === 'Grep' || tool === 'Glob') return { pattern: arg };
    return { file_path: SESS[s].cwd + '/' + arg };
  }
  // one tool call: PreToolUse at t0, PostToolUse at t1
  function use(s, t0, t1, tool, arg, out, x) {
    x = x || {};
    var a = { tool_name: tool, tool_input: input(s, tool, arg), _arg: arg }, b = { tool_name: tool, _out: out };
    for (var k in x) { a[k] = x[k]; b[k] = x[k]; }
    ev(t0, s, 'PreToolUse', a); ev(t1, s, 'PostToolUse', b);
  }
  var A1 = { agent_id: 'a1', agent_type: 'Explore' }, A2 = { agent_id: 'a2', agent_type: 'general-purpose' };
  var ASK_AT = 200, AUTO_ALLOW_AT = 212, LAUNCH = 152;

  // api: the long one. It is the session that will need you.
  ev(14, 's1', 'SessionStart');
  use('s1', 16, 20, 'Read', 'src/auth/session.swift', '212 lines');
  use('s1', 22, 27, 'Grep', 'TokenStore', '9 matches in 4 files');
  ev(30, 's1', 'SubagentStart', { agent_id: 'a1', agent_type: 'Explore', _desc: 'map every caller of TokenStore' });
  use('s1', 33, 46, 'Grep', 'refreshToken', '', A1);
  use('s1', 36, 52, 'Edit', 'src/auth/session.swift', '+38 −21');
  use('s1', 48, 90, 'Read', 'src/api/client.swift', '', A1);
  use('s1', 56, 74, 'Edit', 'src/auth/token.swift', '+64 −40');
  use('s1', 78, 96, 'Bash', 'swift build', 'Build complete (17.2s)');
  use('s1', 92, 150, 'Grep', 'Authorization', '', A1);
  use('s1', 100, 128, 'Edit', 'Tests/AuthTests.swift', '+52 −8');
  use('s1', 132, 138, 'Read', 'src/auth/keychain.swift', '88 lines');
  use('s1', 140, 153, 'Edit', 'src/auth/keychain.swift', '+12 −12');
  use('s1', 155, 172, 'Bash', 'swift build', 'Build complete (16.8s)');
  use('s1', 156, 177, 'Read', 'src/api/middleware.swift', '', A1);
  use('s1', 174, 184, 'Grep', 'legacyToken', '0 matches');
  ev(178, 's1', 'SubagentStop', { agent_id: 'a1', agent_type: 'Explore', _out: '23 files read' });
  use('s1', 186, 196, 'Edit', 'src/auth/session.swift', '+6 −2');
  ev(ASK_AT, 's1', 'PermissionRequest', { tool_name: 'Bash', tool_input: { command: 'swift test --parallel' }, _arg: 'swift test --parallel' });
  use('s1', 213, 240, 'Bash', 'swift test --parallel', 'Executed 14 tests, 0 failures', { _branch: 'allow' });
  use('s1', 244, 258, 'Edit', 'CHANGELOG.md', '+4');
  ev(268, 's1', 'Stop', { _say: 'Auth refactored. 14 tests passing.', _sayDeny: 'Auth refactored. Tests were not run.' });

  // website
  ev(50, 's2', 'SessionStart');
  use('s2', 52, 57, 'Read', 'docs/install.md', '140 lines');
  use('s2', 60, 64, 'Glob', 'docs/**/*.md', '31 files');
  use('s2', 68, 96, 'Edit', 'docs/install.md', '+71 −58');
  use('s2', 100, 106, 'Read', 'docs/faq.md', '96 lines');
  use('s2', 110, 149, 'Edit', 'docs/faq.md', '+18 −9');
  ev(151, 's2', 'SubagentStart', { agent_id: 'a2', agent_type: 'general-purpose', _desc: 'check every link in docs/' });
  use('s2', 152.5, 190, 'Edit', 'docs/index.md', '+9 −3');
  use('s2', 158, 204, 'Bash', 'npm run check-links', '', A2);
  use('s2', 192, 222, 'Bash', 'npm run build', 'Built 31 pages (4.1s)');
  ev(206, 's2', 'SubagentStop', { agent_id: 'a2', agent_type: 'general-purpose', _out: '212 links, 0 broken' });
  ev(226, 's2', 'Stop', { _say: 'Install guide rewritten for 0.2.0.' });

  // mobile
  ev(88, 's3', 'SessionStart');
  use('s3', 90, 100, 'Bash', 'xcrun simctl launch booted app.checkout', 'Crashed: EXC_BAD_ACCESS');
  use('s3', 104, 110, 'Grep', 'CartStore.shared', '6 matches');
  use('s3', 114, 122, 'Read', 'Sources/Cart/CartStore.swift', '164 lines');
  use('s3', 126, 156, 'Edit', 'Sources/Cart/CartStore.swift', '+7 −3');
  use('s3', 157, 186, 'Bash', 'swift test --filter CartTests', 'Executed 9 tests, 0 failures');
  ev(190, 's3', 'Stop', { _say: 'Fixed. CartStore was read before it had loaded.' });

  // infra
  ev(124, 's4', 'SessionStart');
  use('s4', 126, 132, 'Read', 'db/schema.sql', '412 lines');
  use('s4', 136, 142, 'Grep', 'sessions', '27 matches');
  use('s4', 146, 158, 'Write', 'db/migrations/0042_sessions.sql', '+46');
  use('s4', 159, 204, 'Bash', 'make migrate-dry-run', '0042_sessions.sql OK');
  use('s4', 208, 230, 'Edit', 'db/schema.sql', '+11 −4');
  ev(234, 's4', 'Stop', { _say: 'Migration 0042 written. Dry run is clean.' });

  FILM.sort(function (a, b) { return a.t - b.t; });
  var BY_SESSION = {};
  FILM.forEach(function (e) { (BY_SESSION[e._s] = BY_SESSION[e._s] || []).push(e); });

  /* Scroll progress to scene seconds. Time runs fast while the terminals pile
     up and slows right down where there is something to read. */
  var KEYS = [[0.06, 0], [0.34, 150], [0.50, 170], [0.62, 200], [0.76, 216], [0.90, 290], [0.94, 300]];
  function timeAt(p) {
    if (p <= KEYS[0][0]) return (p - KEYS[0][0]) * 200;
    for (var i = 1; i < KEYS.length; i++) {
      if (p <= KEYS[i][0]) { var a = KEYS[i - 1], b = KEYS[i]; return a[1] + (b[1] - a[1]) * (p - a[0]) / (b[0] - a[0]); }
    }
    return 300 + (p - 0.94) * 100;
  }
  function pAt(T) {
    for (var i = 1; i < KEYS.length; i++) {
      if (T <= KEYS[i][1]) { var a = KEYS[i - 1], b = KEYS[i]; return a[0] + (b[0] - a[0]) * (T - a[1]) / (b[1] - a[1]); }
    }
    return 0.94;
  }

  // The visitor's own answer to the permission card, if they gave one.
  var userDec = null;
  function decisionAt(T) {
    if (T < ASK_AT - 1) { userDec = null; return null; }
    if (userDec) return userDec.t <= T ? userDec : null;
    return T >= AUTO_ALLOW_AT ? { allow: true, t: AUTO_ALLOW_AT, auto: true } : null;
  }

  function filmStore(T) {
    var st = new AgentStore();
    if (T < LAUNCH) return st;                 // the app is not open yet; it saw nothing
    var dec = decisionAt(T), branch = dec && !dec.allow ? 'deny' : 'allow', decided = false;
    var noop = function () {};
    var applyDec = function () { st.sweep(dec.t); if (st.pending[0]) st.decide(st.pending[0].id, dec.allow); decided = true; };
    for (var i = 0; i < FILM.length; i++) {
      var e = FILM[i];
      if (e.t > T) break;
      if (e.t < LAUNCH) continue;
      if (dec && !decided && dec.t <= e.t) applyDec();
      if (e._branch && e._branch !== branch) continue;
      st.sweep(e.t);
      st.handle(e, e.t, noop);
    }
    if (dec && !decided) applyDec();
    st.sweep(T);
    return st;
  }

  /* ============================================================== TERMINALS */
  var CARET = '<span class="caret"></span>';
  function termHTML(s, T) {
    var m = SESS[s], t0 = m.open, L = [];
    var n1 = Math.round(ramp(T, t0 + 2.5, t0 + 5) * 6);
    L.push('<span class="u">' + m.dir + '</span> <span class="g">❯</span> ' + 'claude'.slice(0, n1) + (T < t0 + 5.6 ? CARET : ''));
    if (T < t0 + 5.6) return wrap(L);
    var n2 = Math.round(ramp(T, t0 + 6.5, t0 + 12.5) * m.prompt.length);
    L.push('<span class="d">&gt;</span> <span class="w">' + esc(m.prompt.slice(0, n2)) + '</span>' + (T < t0 + 13 ? CARET : ''));

    var dec = decisionAt(T), branch = dec && !dec.allow ? 'deny' : 'allow';
    var lines = [], open = null, tasks = {}, started = null, stopped = false, asking = null;
    BY_SESSION[s].forEach(function (e) {
      if (e.t > T) return;
      if (e._branch && e._branch !== branch) return;
      var n = e.hook_event_name, sub = e.agent_id != null;
      if (started === null) started = e.t;
      if (n === 'SubagentStart') { tasks[e.agent_id] = { call: 'Task', arg: e.agent_type + ': ' + e._desc, live: true }; lines.push(tasks[e.agent_id]); }
      else if (n === 'SubagentStop') { if (tasks[e.agent_id]) { tasks[e.agent_id].live = false; tasks[e.agent_id].res = e.agent_type + ' finished · ' + e._out; } }
      else if (sub) { /* a sub-agent's own tools do not print in the parent's terminal */ }
      else if (n === 'PreToolUse') {
        if (asking && asking.call === e.tool_name && asking.arg === e._arg) { open = asking; open.ask = false; asking = null; }   // approved: same line carries on
        else { open = { call: e.tool_name, arg: e._arg, live: true }; lines.push(open); }
      }
      else if (n === 'PostToolUse') { if (open) { open.live = false; open.res = e._out; open = null; } }
      else if (n === 'PermissionRequest') { asking = { call: e.tool_name, arg: e._arg, live: true, ask: true }; lines.push(asking); }
      else if (n === 'Stop') { stopped = true; lines.push({ say: branch === 'deny' && e._sayDeny ? e._sayDeny : e._say }); }
    });
    if (asking && dec) { asking.ask = false; asking.live = false; if (!dec.allow) { asking.denied = true; asking.res = 'Denied from Notch Agents'; } else asking.live = true; }

    lines.forEach(function (l) {
      if (l.say) { L.push('<span class="g">●</span> <span class="w">' + esc(l.say) + '</span>'); return; }
      L.push('<span class="' + (l.denied ? 'd' : l.live ? 'o' : 'g') + '">●</span> ' + l.call + '<span class="d">(' + esc(l.arg) + ')</span>');
      if (l.res) L.push('<span class="d">  └ ' + esc(l.res) + '</span>');
      if (l.ask) {
        L.push('<span class="tl-ask">  Do you want to proceed?</span>');
        L.push('<span class="o">  ❯ 1. Yes</span><span class="d">    2. No</span>');
      }
    });
    if (started !== null && !stopped) {
      L.push(asking && asking.ask
        ? '<span class="d">  waiting for you</span>'
        : '<span class="o pulse">*</span> <span class="d">Working… (' + fmt(T - started) + ')</span>');
    }
    return wrap(L);
  }
  function wrap(L) { return L.map(function (h) { return '<div class="tl">' + h + '</div>'; }).join(''); }

  var terms = $$('.term').map(function (el) {
    var s = el.dataset.s;
    return { el: el, s: s, body: $('.term__body', el), at: pAt(SESS[s].open) - 0.004, html: '', o: -1 };
  });

  /* ================================================================ THE FILM */
  var sc = window.ScrollCraft.mount(document.body);
  var filmAct = sc.acts.filter(function (a) { return a.el.id === 'top'; })[0];
  var desk = $('#desk'), curtain = $('#curtain'), mbStatus = $('#mbStatus'), dockTerm = $('#dockTerm'), deskNote = $('#deskNote');
  var liveStore = new AgentStore();
  var dirty = true, lastP = -1, lastT = 0, mode = 'film', vw = innerWidth, vh = innerHeight;
  var mx = 0, my = 0, tmx = 0, tmy = 0;

  function maxZoom() {
    if (reduce || vw < 861) return 1;
    return clamp(Math.min((vh - 170) / 400, vw * 0.42 / 340), 1, 1.75);
  }

  function drawFilm(p) {
    var T = timeAt(p);
    lastT = T;

    // camera: push in on the notch, hold, pull back
    var focus = smooth(ramp(p, 0.40, 0.48)) * (1 - smooth(ramp(p, 0.80, 0.87)));
    root.style.setProperty('--focus', focus.toFixed(4));
    root.style.setProperty('--zoom', (1 + (maxZoom() - 1) * focus).toFixed(4));
    desk.classList.toggle('pulling', focus > 0.001 && !reduce);
    desk.style.setProperty('--drift', reduce ? '0' : smooth(ramp(p, 0, 0.36)).toFixed(4));

    // windows open in the order the sessions start
    var front = -1;
    terms.forEach(function (t, i) {
      var o = reduce ? (p >= t.at ? 1 : 0) : smooth(ramp(p, t.at, t.at + 0.024));
      if (o !== t.o) { t.o = o; t.el.style.setProperty('--o', o.toFixed(3)); t.el.classList.toggle('open', o > 0); }
      if (o > 0.5) front = i;
      if (o > 0) { var h = termHTML(t.s, T); if (h !== t.html) { t.html = h; t.body.innerHTML = h; t.body.scrollTop = t.body.scrollHeight; } }
    });
    terms.forEach(function (t, i) { t.el.classList.toggle('front', i === front); t.el.style.zIndex = i === front ? 9 : i + 1; });
    dockTerm.classList.toggle('running', front >= 0);
    deskNote.classList.toggle('on', p > 0.09 && p < 0.9);

    // the app itself: launched late, on purpose
    mbStatus.classList.toggle('on', T >= LAUNCH - 2);
    var store = filmStore(T);
    drawIsland(store, T, T >= LAUNCH, p >= 0.455 && p < 0.80);
    islAllow.classList.toggle('pressing', !userDec && T >= AUTO_ALLOW_AT - 0.8 && T < AUTO_ALLOW_AT);
    islCard.classList.toggle('unarmed', T < ASK_AT + 0.7);

    // the way out: the notch swallows the screen
    var c = smooth(ramp(p, 0.935, 1));
    if (c <= 0) { curtain.style.visibility = 'hidden'; }
    else {
      curtain.style.visibility = 'visible';
      var k = Math.round(c * 10), col = 'rgb(' + k + ' ' + Math.round(c * 11) + ' ' + Math.round(c * 14) + ')';
      curtain.style.background = col;
      if (reduce) { curtain.style.clipPath = 'none'; curtain.style.opacity = c.toFixed(3); }
      else {
        var nw = parseFloat(getComputedStyle(root).getPropertyValue('--notch-w')) || 200;
        var side = (vw / 2 - nw / 2) * (1 - c), bottom = (vh - 32) * (1 - c), r = 10 + c * (1 - c) * 320;
        curtain.style.clipPath = 'inset(0 ' + side.toFixed(1) + 'px ' + bottom.toFixed(1) + 'px ' + side.toFixed(1) + 'px round 0 0 ' + r.toFixed(1) + 'px ' + r.toFixed(1) + 'px)';
      }
    }
  }

  function setMode(m) {
    if (m === mode) return;
    mode = m; document.body.dataset.mode = m;
    if (m === 'film') { liveStore = new AgentStore(); labReset(); }
    else { drawFilm(1); lastP = 1; root.style.setProperty('--focus', '0'); root.style.setProperty('--zoom', '1'); mbStatus.classList.add('on'); islCard.classList.remove('unarmed'); islAllow.classList.remove('pressing'); }
    hovering = false; dirty = true;
  }

  function frame() {
    var p = filmAct ? filmAct.raw : 1;
    setMode(p >= 0.9995 ? 'doc' : 'film');
    if (finePointer && !reduce && mode === 'film') {
      mx += (tmx - mx) * 0.07; my += (tmy - my) * 0.07;
      if (Math.abs(tmx - mx) > 0.002 || Math.abs(tmy - my) > 0.002) { desk.style.setProperty('--mx', mx.toFixed(3)); desk.style.setProperty('--my', my.toFixed(3)); }
    }
    if (mode === 'film') {
      if (p !== lastP || dirty) { lastP = p; dirty = false; drawFilm(p); }
    } else if (dirty) {
      dirty = false; lastP = p;
      liveStore.sweep(now());
      drawIsland(liveStore, now(), true, false);
    }
    requestAnimationFrame(frame);
  }
  function now() { return performance.now() / 1000; }

  addEventListener('resize', function () { vw = innerWidth; vh = innerHeight; dirty = true; }, { passive: true });
  if (finePointer) addEventListener('pointermove', function (e) {
    tmx = (e.clientX / vw - 0.5) * 2; tmy = (e.clientY / vh - 0.5) * 2;
  }, { passive: true });
  // below the desktop the island runs on the wall clock
  setInterval(function () { if (mode === 'doc' && (liveStore.isVisible() || island.dataset.state !== 'hidden')) dirty = true; }, 250);

  // Allow / Deny on the island. Buttons stay inert briefly after the card
  // appears, as in the app, so a click already in flight cannot approve it.
  function answer(allow) {
    if (!shownPrompt) return;
    if (mode === 'film') {
      if (lastT < ASK_AT + 0.7) return;
      userDec = { allow: allow, t: lastT };
    } else {
      if (now() - shownPrompt.createdAt < 0.7) return;
      liveStore.decide(shownPrompt.id, allow);
    }
    dirty = true;
  }

  /* ============================================================ SEND A HOOK */
  var LAB_BASE = { session_id: 'e5172fbe-4c1d', cwd: '/Users/you/code/api', session_title: 'Refactor auth module' };
  function lab(name, tag, say, extra) {
    var e = { hook_event_name: name };
    for (var k in LAB_BASE) e[k] = LAB_BASE[k];
    for (var x in extra) e[x] = extra[x];
    return { name: name, tag: tag, say: say, e: e };
  }
  var SUB = { agent_id: 'a1', agent_type: 'Explore' };
  var LAB = [
    lab('PreToolUse', 'Read', 'A row appears: the chat, its project, the tool, a timer.', { tool_name: 'Read', tool_input: { file_path: '/Users/you/code/api/src/auth/session.swift' } }),
    lab('SubagentStart', 'Explore', 'A sub-agent gets a row of its own.', SUB),
    lab('PreToolUse', 'sub-agent', 'Its row shows what it is searching for.', { agent_id: 'a1', agent_type: 'Explore', tool_name: 'Grep', tool_input: { pattern: 'TokenStore' } }),
    lab('SubagentStop', 'Explore', 'Its dot turns green. Eight seconds later the row is gone.', SUB),
    lab('PermissionRequest', 'Bash', 'The island opens and asks. Your answer goes back to Claude.', { tool_name: 'Bash', tool_input: { command: 'swift test --parallel' } }),
    lab('PostToolUse', 'Bash', 'The tool ran. The agent is thinking again.', { tool_name: 'Bash' }),
    lab('Stop', '', 'The session finished its turn. Green, then tidied away.', {})
  ];
  var labList = $('#labList'), labJson = $('#labJson'), labStdout = $('#labStdout'), labBtns = [];

  function hl(obj) {
    return esc(JSON.stringify(obj, null, 2))
      .replace(/(&quot;[^&]*?&quot;)(\s*:)/g, '<span class="k">$1</span>$2')
      .replace(/: (&quot;.*?&quot;)(,?)$/gm, ': <span class="s">$1</span>$2');
  }
  function stdout(html) { labStdout.innerHTML = html; }
  function labSelect(i) {
    labBtns.forEach(function (b, j) { b.classList.toggle('on', j === i); b.classList.toggle('next', j === i + 1 && !b.classList.contains('sent')); });
    labJson.innerHTML = hl(LAB[i].e);
  }
  function labSend(i) {
    var item = LAB[i];
    if (mode !== 'doc') return;
    labBtns[i].classList.add('sent');
    labSelect(i);
    if (item.name === 'PermissionRequest') stdout('<span class="c">waiting up to 25s for your answer at the notch ↑</span>');
    else stdout('<span class="c">(nothing. The script exits 0 at once.)</span>');
    liveStore.sweep(now());
    liveStore.handle(item.e, now(), function (json) {
      stdout(json ? hl(JSON.parse(json)) : '<span class="c">(nothing. Claude asks in the terminal instead.)</span>');
    });
    dirty = true;
  }
  function labReset() {
    labBtns.forEach(function (b, j) { b.classList.remove('sent', 'on'); b.classList.toggle('next', j === 0); });
    labJson.innerHTML = hl(LAB[0].e);
    stdout('<span class="c">Press an event on the left.</span>');
  }
  LAB.forEach(function (item, i) {
    var li = document.createElement('li'), b = document.createElement('button');
    b.type = 'button'; b.className = 'lab__ev';
    b.innerHTML = '<i class="n"></i><b>' + item.name + (item.tag ? ' <i>· ' + item.tag + '</i>' : '') + '</b><span>' + item.say + '</span>';
    b.addEventListener('click', function () { labSend(i); });
    li.appendChild(b); labList.appendChild(li); labBtns.push(b);
  });
  labReset();
  // Walk away from the panel and the sample session wraps itself up.
  if ('IntersectionObserver' in window) {
    new IntersectionObserver(function (es) {
      if (es[0].isIntersecting || mode !== 'doc' || !liveStore.isVisible()) return;
      var t = now();
      liveStore.handle(LAB[3].e, t); liveStore.handle(LAB[6].e, t); dirty = true;
    }, { threshold: 0 }).observe($('#how'));
  }

  /* ================================================================= CLOSE */
  // Drag the app onto Applications, as you would in the real disk image.
  (function () {
    var app = $('#dmgApp'), dest = $('#dmgDest'), hint = $('#dmgHint');
    if (!app) return;
    var d = null, swallow = false;
    var over = function (e) { var r = dest.getBoundingClientRect(); return e.clientX > r.left - 24 && e.clientX < r.right + 24 && e.clientY > r.top - 24 && e.clientY < r.bottom + 24; };
    app.addEventListener('pointerdown', function (e) {
      if (e.button) return;
      d = { x: e.clientX, y: e.clientY, moved: false };
      app.classList.remove('back', 'gone');
      try { app.setPointerCapture(e.pointerId); } catch (_) {}
    });
    app.addEventListener('pointermove', function (e) {
      if (!d) return;
      var dx = e.clientX - d.x, dy = e.clientY - d.y;
      if (!d.moved && Math.abs(dx) + Math.abs(dy) < 6) return;
      d.moved = true; app.classList.add('drag');
      app.style.transform = 'translate3d(' + dx + 'px,' + dy + 'px,0) scale(1.05)';
      dest.classList.toggle('over', over(e));
    });
    var end = function (e) {
      if (!d) return;
      var moved = d.moved, hit = moved && e.type === 'pointerup' && over(e);
      d = null; app.classList.remove('drag'); dest.classList.remove('over');
      if (!moved) return;                      // a plain click is a plain download link
      swallow = true; setTimeout(function () { swallow = false; }, 0);
      if (hit) {
        var a = app.getBoundingClientRect(), r = dest.getBoundingClientRect();
        var cur = (app.style.transform.match(/translate3d\(([-\d.]+)px,\s*([-\d.]+)px/) || [0, 0, 0]).slice(1).map(Number);
        app.classList.add('gone');
        app.style.transform = 'translate3d(' + (cur[0] + (r.left + r.width / 2) - (a.left + a.width / 2)) + 'px,' + (cur[1] + (r.top + r.height / 2) - (a.top + a.height / 2) - 14) + 'px,0) scale(0.45)';
        hint.textContent = 'Downloading. Open the disk image and do that again.';
        setTimeout(function () { location.href = app.href; }, 320);
        setTimeout(function () { app.classList.remove('gone'); app.classList.add('back'); app.style.transform = ''; }, 2200);
      } else {
        app.classList.add('back'); app.style.transform = '';
      }
    };
    app.addEventListener('pointerup', end);
    app.addEventListener('pointercancel', end);
    app.addEventListener('click', function (e) { if (swallow) e.preventDefault(); });
    app.addEventListener('dragstart', function (e) { e.preventDefault(); });
  })();

  var copyBtn = $('#srcCopy');
  if (copyBtn) copyBtn.addEventListener('click', function () {
    var txt = $('#srcCmd').textContent.trim();
    var done = function () { copyBtn.textContent = 'Copied'; setTimeout(function () { copyBtn.textContent = 'Copy'; }, 1600); };
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(txt).then(done, function () {});
  });

  /* ================================================================ CHROME */
  var clock = $('#mbClock');
  function tick() {
    var d = new Date();
    var day = d.toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' }).replace(/,/g, '');
    clock.textContent = day + '  ' + d.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
    clock.dateTime = d.toISOString();
  }
  tick(); setInterval(tick, 15000);

  // Point the download buttons straight at the newest disk image. Until this
  // answers (or if it never does) they go to the releases page, which works.
  (function () {
    var apply = function (rel) {
      if (!rel || !/^https:\/\/github\.com\/adii9\/notch-agents\/releases\/download\//.test(rel.url)) return;
      $$('[data-dl]').forEach(function (a) { a.href = rel.url; });
      $$('[data-ver]').forEach(function (el) { el.textContent = rel.tag; });
      if (rel.size) $$('[data-size]').forEach(function (el) { el.textContent = (rel.size / 1e6).toFixed(1) + ' MB'; });
    };
    try { var cached = JSON.parse(sessionStorage.getItem('na-release') || 'null'); if (cached) { apply(cached); return; } } catch (_) {}
    if (!window.fetch) return;
    fetch('https://api.github.com/repos/adii9/notch-agents/releases/latest', { headers: { Accept: 'application/vnd.github+json' } })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (j) {
        if (!j || !j.assets) return;
        var dmg = j.assets.filter(function (a) { return /\.dmg$/i.test(a.name); })[0];
        if (!dmg) return;
        var rel = { url: dmg.browser_download_url, tag: String(j.tag_name || '').slice(0, 24), size: dmg.size };
        apply(rel);
        try { sessionStorage.setItem('na-release', JSON.stringify(rel)); } catch (_) {}
      }).catch(function () {});
  })();

  requestAnimationFrame(frame);
})();
