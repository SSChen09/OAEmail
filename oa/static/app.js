'use strict';

/* ============================================================
   ddzt.old 协同办公 OA —— 演示展示版前端逻辑
   邮件模块对接 api/mail.php；公告/日程对接 api/content.php；其余模块为演示数据
   ============================================================ */

/* ===================== 演示数据（集中定义，方便替换） ===================== */

const DEMO_STATS = { todos: 8, notices: 5, attendance: 22 };

const APPROVALS = [
  { id: 1, applicant: '张伟', type: '请假', time: '2026-11-12 09:15', status: '待审批' },
  { id: 2, applicant: '李娜', type: '报销', time: '2026-11-12 08:52', status: '待审批' },
  { id: 3, applicant: '王强', type: '用章', time: '2026-11-11 17:40', status: '待审批' },
  { id: 4, applicant: '赵敏', type: '采购', time: '2026-11-11 15:26', status: '待审批' },
  { id: 5, applicant: '刘洋', type: '请假', time: '2026-11-11 10:08', status: '已通过' },
  { id: 6, applicant: '陈静', type: '报销', time: '2026-11-10 16:33', status: '待审批' },
  { id: 7, applicant: '杨帆', type: '采购', time: '2026-11-10 11:47', status: '已驳回' },
  { id: 8, applicant: 'eva', type: '用章', time: '2026-11-09 14:20', status: '已通过' }
];

const EMPLOYEES = [
  { no: 'DD1001', name: 'eva', dept: '行政部', title: '行政专员', phone: '138****1001', email: 'eva@ddzt.old', hire: '2024-03-11' },
  { no: 'DD1002', name: 'kk', dept: '技术部', title: '运维工程师', phone: '138****1002', email: 'kk@ddzt.old', hire: '2024-05-06' },
  { no: 'DD1003', name: '张伟', dept: '市场部', title: '市场经理', phone: '138****1003', email: 'zhangwei@ddzt.old', hire: '2023-07-18' },
  { no: 'DD1004', name: '李娜', dept: '财务部', title: '会计', phone: '138****1004', email: 'lina@ddzt.old', hire: '2023-09-01' },
  { no: 'DD1005', name: '王强', dept: '技术部', title: '软件工程师', phone: '138****1005', email: 'wangqiang@ddzt.old', hire: '2025-01-13' },
  { no: 'DD1006', name: '赵敏', dept: '人力资源部', title: '招聘主管', phone: '138****1006', email: 'zhaomin@ddzt.old', hire: '2022-11-21' },
  { no: 'DD1007', name: '刘洋', dept: '市场部', title: '客户经理', phone: '138****1007', email: 'liuyang@ddzt.old', hire: '2025-04-07' },
  { no: 'DD1008', name: '陈静', dept: '行政部', title: '前台文员', phone: '138****1008', email: 'chenjing@ddzt.old', hire: '2026-02-24' }
];

const DOCS = [
  { name: '2026 年度行政管理制度汇编.docx', type: 'doc', size: '2.4 MB', time: '2026-11-11 16:20' },
  { name: '11 月员工考勤汇总表.xlsx', type: 'xls', size: '386 KB', time: '2026-11-11 09:42' },
  { name: '年度工作总结大会汇报模板.pptx', type: 'ppt', size: '5.1 MB', time: '2026-11-10 14:05' },
  { name: '内网信息安全保密手册.pdf', type: 'pdf', size: '3.8 MB', time: '2026-11-08 11:30' },
  { name: '办公用品采购申请单模板.docx', type: 'doc', size: '124 KB', time: '2026-11-06 15:12' },
  { name: '新员工入职指引手册.pdf', type: 'pdf', size: '1.9 MB', time: '2026-11-04 10:26' },
  { name: '部门周报模板（2026 版）.xlsx', type: 'xls', size: '98 KB', time: '2026-10-30 17:48' },
  { name: '历年规章制度归档备份.zip', type: 'zip', size: '28.6 MB', time: '2026-10-27 09:03' }
];

const CONTACTS = [
  { name: 'eva', dept: '行政部', title: '行政专员', phone: '138****1001', email: 'eva@ddzt.old' },
  { name: 'kk', dept: '技术部', title: '运维工程师', phone: '138****1002', email: 'kk@ddzt.old' },
  { name: '张伟', dept: '市场部', title: '市场经理', phone: '138****1003', email: 'zhangwei@ddzt.old' },
  { name: '李娜', dept: '财务部', title: '会计', phone: '138****1004', email: 'lina@ddzt.old' },
  { name: '王强', dept: '技术部', title: '软件工程师', phone: '138****1005', email: 'wangqiang@ddzt.old' },
  { name: '赵敏', dept: '人力资源部', title: '招聘主管', phone: '138****1006', email: 'zhaomin@ddzt.old' },
  { name: '刘洋', dept: '市场部', title: '客户经理', phone: '138****1007', email: 'liuyang@ddzt.old' },
  { name: '陈静', dept: '行政部', title: '前台文员', phone: '138****1008', email: 'chenjing@ddzt.old' }
];

const QUICK_LINKS = [
  { route: '#/notices', icon: '📢', label: '公告通知' },
  { route: '#/approvals', icon: '✅', label: '流程审批' },
  { route: '#/hr', icon: '👥', label: '人事管理' },
  { route: '#/schedule', icon: '📅', label: '日程安排' },
  { route: '#/docs', icon: '📁', label: '文档中心' },
  { route: '#/contacts', icon: '📇', label: '通讯录' },
  { route: '#/mail', icon: '✉️', label: '邮件' },
  { route: '#/settings', icon: '⚙️', label: '系统设置' },
  { route: '#/mail', icon: '✍️', label: '写邮件' }
];

const TODOS = [
  { id: 1, text: '提交 11 月部门考勤汇总表', date: '11-13 截止', done: false },
  { id: 2, text: '审核办公用品采购申请（3 笔）', date: '11-12 截止', done: false },
  { id: 3, text: '准备年度工作总结大会部门汇报材料', date: '11-17 截止', done: false },
  { id: 4, text: '回复技术部服务器机房巡检结果', date: '11-12 截止', done: false },
  { id: 5, text: '整理新员工入职档案（陈静）', date: '11-14 截止', done: false },
  { id: 6, text: '更新内网通讯录分机号', date: '11-16 截止', done: true },
  { id: 7, text: '确认生日会场地布置方案', date: '11-13 截止', done: false },
  { id: 8, text: '归档 10 月用章审批记录', date: '11-15 截止', done: false }
];

const AVATAR_COLORS = ['#4f6ef7', '#7c5cf0', '#0ea5e9', '#16a34a', '#f59e0b', '#e5484d', '#06b6d4', '#8b5cf6'];

/* ===================== 基础工具 ===================== */

function $(sel) { return document.querySelector(sel); }

function esc(value) {
  return String(value == null ? '' : value).replace(/[&<>"']/g, function (ch) {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch];
  });
}

function toast(message, type) {
  const box = $('#toast-box');
  const node = document.createElement('div');
  node.className = 'toast' + (type ? ' ' + type : '');
  node.textContent = message;
  box.appendChild(node);
  setTimeout(function () { node.remove(); }, 2600);
}

function openModal(title, html) {
  $('#modal-title').textContent = title;
  $('#modal-body').innerHTML = html;
  $('#modal-root').classList.remove('hidden');
}

function closeModal() {
  $('#modal-root').classList.add('hidden');
  $('#modal-body').innerHTML = '';
}

/* ===================== 登录 / 登出（服务端会话） ===================== */

const OA = { user: null, role: 'user' };

/* 仅管理员可以修改/保存 OA 内容；普通账号只读 */
function isAdmin() {
  return OA.role === 'admin';
}

/* OA 账号接口：api/auth.php，返回 {ok:true,data} / {ok:false,error} */
async function oaApi(action, fields) {
  const body = new URLSearchParams();
  body.set('action', action);
  if (fields) {
    Object.keys(fields).forEach(function (k) { body.set(k, fields[k]); });
  }
  try {
    const res = await fetch('api/auth.php', {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: body.toString()
    });
    const text = await res.text();
    let data;
    try {
      data = JSON.parse(text);
    } catch (parseErr) {
      return { ok: false, error: '登录服务返回了异常内容' };
    }
    if (!res.ok) data.ok = false;
    return data;
  } catch (netErr) {
    return { ok: false, error: '无法连接登录服务，请稍后重试' };
  }
}

async function enterApp(user, role) {
  OA.user = user;
  OA.role = role === 'admin' ? 'admin' : 'user';
  $('#current-user').textContent = user;
  const tag = $('#role-tag');
  if (tag) {
    tag.textContent = isAdmin() ? '管理员' : '只读用户';
    tag.className = 'role-tag ' + (isAdmin() ? 'role-admin' : 'role-user');
  }
  $('#login-page').classList.add('hidden');
  $('#app').classList.remove('hidden');
  await loadContent(true);
  if (!location.hash) location.hash = '#/dashboard';
  navigate();
}

function exitApp() {
  OA.user = null;
  OA.role = 'user';
  CONTENT.notices = [];
  CONTENT.schedule = [];
  CONTENT.loaded = false;
  sessionStorage.removeItem('oa_user');
  $('#app').classList.add('hidden');
  $('#login-page').classList.remove('hidden');
  $('#login-form').reset();
}

/* ===================== 公告 / 日程内容（服务端持久化，管理员可写） ===================== */

const CONTENT = { notices: [], schedule: [], loaded: false };

/* 调用 api/content.php；action=data 用 GET 读取，其余用 POST 写入 */
async function contentRequest(action, fields) {
  const options = { credentials: 'same-origin' };
  let url = 'api/content.php';
  if (action === 'data') {
    url += '?action=data';
    options.method = 'GET';
  } else {
    const body = new URLSearchParams();
    body.set('action', action);
    Object.keys(fields || {}).forEach(function (key) { body.set(key, fields[key]); });
    options.method = 'POST';
    options.headers = { 'Content-Type': 'application/x-www-form-urlencoded' };
    options.body = body.toString();
  }
  try {
    const res = await fetch(url, options);
    const text = await res.text();
    let data;
    try {
      data = JSON.parse(text);
    } catch (parseErr) {
      return { ok: false, error: '内容服务返回了异常内容' };
    }
    if (!res.ok) data.ok = false;
    return data;
  } catch (netErr) {
    return { ok: false, error: '无法连接内容服务，请稍后重试' };
  }
}

async function loadContent(force) {
  if (CONTENT.loaded && !force) return true;
  const res = await contentRequest('data');
  if (!res || res.ok !== true) {
    if (!CONTENT.loaded) toast((res && res.error) ? res.error : '加载公告与日程失败', 'error');
    return false;
  }
  CONTENT.notices = Array.isArray(res.data.notices) ? res.data.notices : [];
  CONTENT.schedule = Array.isArray(res.data.schedule) ? res.data.schedule : [];
  CONTENT.loaded = true;
  return true;
}

/* 管理员保存/删除；成功后用响应里的最新数据刷新本地缓存 */
async function contentMutate(action, fields) {
  const res = await contentRequest(action, fields);
  if (!res || res.ok !== true) {
    toast((res && res.error) ? res.error : '保存失败，请稍后重试', 'error');
    return false;
  }
  const data = res.data || {};
  if (Array.isArray(data.notices)) CONTENT.notices = data.notices;
  if (Array.isArray(data.schedule)) CONTENT.schedule = data.schedule;
  CONTENT.loaded = true;
  toast(data.message || '已保存', 'success');
  return true;
}

function confirmDelete(text, onConfirm) {
  openModal('确认删除',
    '<p class="confirm-text">' + esc(text) + ' 删除后不可恢复，确定继续吗？</p>' +
    '<div class="modal-actions">' +
      '<button type="button" class="btn btn-ghost" id="confirm-cancel">取消</button>' +
      '<button type="button" class="btn btn-danger" id="confirm-ok">删除</button>' +
    '</div>');
  $('#confirm-cancel').addEventListener('click', closeModal);
  $('#confirm-ok').addEventListener('click', async function () {
    this.disabled = true;
    this.textContent = '删除中…';
    const ok = await onConfirm();
    if (ok) closeModal();
    else { this.disabled = false; this.textContent = '删除'; }
  });
}

function todayStr() {
  const d = new Date();
  const pad = function (n) { return (n < 10 ? '0' : '') + n; };
  return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());
}

/* ===================== 邮件 API 封装（真实功能） ===================== */

const MAIL = {
  user: null,
  messages: [],
  selected: null,
  folder: 'INBOX',
  counts: { INBOX: 0, Sent: 0 }
};

const MAIL_MAX_FILES = 10;                    /* 与后端 MAX_ATTACH_FILES 保持一致 */
const MAIL_MAX_BYTES = 20 * 1024 * 1024;      /* 与后端 MAX_ATTACH_TOTAL 保持一致 */

/* 统一发请求：body 可以是字符串（普通表单编码）或 FormData（带附件） */
async function mailRequest(body) {
  const options = { method: 'POST', credentials: 'same-origin', body: body };
  if (typeof body === 'string') {
    options.headers = { 'Content-Type': 'application/x-www-form-urlencoded' };
  }
  try {
    const res = await fetch('api/mail.php', options);
    if (!res.ok) {
      return {
        ok: false,
        error: res.status === 413 ? '附件太大，服务器拒绝接收（413）'
                                 : '邮件服务返回错误（HTTP ' + res.status + '）'
      };
    }
    const text = await res.text();
    try {
      return JSON.parse(text);
    } catch (parseErr) {
      return { ok: false, error: '邮件服务返回了异常内容' };
    }
  } catch (err) {
    return { ok: false, error: '请求失败，无法连接邮件服务' };
  }
}

/* attachments 为 File 数组时走 multipart/form-data，否则走普通表单编码 */
async function mailApi(action, params, attachments) {
  if (attachments && attachments.length) {
    const form = new FormData();
    form.append('action', action);
    Object.keys(params || {}).forEach(function (key) {
      form.append(key, params[key]);
    });
    attachments.forEach(function (file) {
      form.append('attachments[]', file, file.name);
    });
    return mailRequest(form);
  }
  const body = new URLSearchParams();
  body.append('action', action);
  Object.keys(params || {}).forEach(function (key) {
    body.append(key, params[key]);
  });
  return mailRequest(body.toString());
}

/* 调用邮件接口：成功返回 data，失败返回 null 并 toast 错误信息（silent=true 不提示） */
async function mailCall(action, params, silent) {
  const result = await mailApi(action, params);
  if (!result || result.ok !== true) {
    const message = (result && result.error) ? result.error : '请求失败，请稍后重试';
    if (!silent) toast(message, 'error');
    return null;
  }
  return result.data;
}

async function refreshMailList(silent, folder) {
  const target = folder || MAIL.folder || 'INBOX';
  const data = await mailCall('list', { folder: target }, silent);
  if (data && data.messages) {
    MAIL.messages = data.messages;
    MAIL.folder = data.folder || target;
    if (data.counts) MAIL.counts = data.counts;
    return true;
  }
  return false;
}

/* ===================== 工作台 ===================== */

function renderDashboard() {
  $('#content').innerHTML =
    '<div class="stat-grid">' +
      '<div class="stat-card"><div class="stat-icon i-blue">📋</div><div><div class="stat-num">' + DEMO_STATS.todos + '</div><div class="stat-label">待办事项</div></div></div>' +
      '<div class="stat-card"><div class="stat-icon i-purple">📢</div><div><div class="stat-num">' + CONTENT.notices.length + '</div><div class="stat-label">公告通知</div></div></div>' +
      '<div class="stat-card"><div class="stat-icon i-green">🗓️</div><div><div class="stat-num">' + DEMO_STATS.attendance + ' 天</div><div class="stat-label">本月考勤</div></div></div>' +
      '<div class="stat-card"><div class="stat-icon i-orange">✉️</div><div><div class="stat-num" id="stat-unread">—</div><div class="stat-label">未读邮件</div></div></div>' +
    '</div>' +
    '<div class="card"><div class="card-title">🚀 快捷入口</div><div class="quick-grid">' +
      QUICK_LINKS.map(function (item) {
        return '<a class="quick-item" href="' + item.route + '"><span class="q-icon">' + item.icon + '</span><span class="q-label">' + item.label + '</span></a>';
      }).join('') +
    '</div></div>' +
    '<div class="card"><div class="card-title">📢 最新公告<span class="more" id="more-notices">查看全部 &gt;</span></div>' +
      (CONTENT.notices.length
        ? CONTENT.notices.slice(0, 3).map(function (n) {
            return '<div class="todo-item row-click" data-notice="' + n.id + '"><span>' + (n.pinned ? '📌' : '📄') + '</span><span class="todo-text">' + esc(n.title) + (n.pinned ? '<span class="badge-pin">置顶</span>' : '') + '</span><span class="todo-date">' + esc(n.date) + '</span></div>';
          }).join('')
        : '<div class="todo-item"><span>📭</span><span class="todo-text">暂无公告</span></div>') +
    '</div>' +
    '<div class="card"><div class="card-title">✅ 我的待办清单' +
      (isAdmin() ? '' : '<span class="readonly-hint">只读 · 仅管理员可勾选</span>') +
    '</div><div id="todo-list">' +
      TODOS.map(function (t) {
        return '<label class="todo-item' + (t.done ? ' done' : '') + '" data-todo="' + t.id + '">' +
          '<input type="checkbox"' + (t.done ? ' checked' : '') + (isAdmin() ? '' : ' disabled title="仅管理员可修改"') + '>' +
          '<span class="todo-text">' + esc(t.text) + '</span>' +
          '<span class="todo-date">' + esc(t.date) + '</span></label>';
      }).join('') +
    '</div></div>';

  $('#content').querySelectorAll('[data-notice]').forEach(function (row) {
    row.addEventListener('click', function () { openNoticeModal(Number(row.dataset.notice)); });
  });
  const more = $('#more-notices');
  if (more) more.addEventListener('click', function () { location.hash = '#/notices'; });
  $('#content').querySelectorAll('[data-todo]').forEach(function (label) {
    const box = label.querySelector('input[type="checkbox"]');
    if (!box) return;
    box.addEventListener('change', function () {
      if (!isAdmin()) {
        box.checked = !box.checked;
        toast('仅管理员可修改待办状态', 'error');
        return;
      }
      const item = TODOS.filter(function (t) { return String(t.id) === label.dataset.todo; })[0];
      if (item) item.done = box.checked;
      label.classList.toggle('done', box.checked);
    });
  });

  loadUnreadCount();
}

/* 未读邮件数：从邮件 API list 结果里数 seen=false 的条数，失败显示 "—" */
async function loadUnreadCount() {
  const el = $('#stat-unread');
  if (!el) return;
  const me = await mailCall('me', null, true);
  if (!me || !me.user) { el.textContent = '—'; return; }
  const data = await mailCall('list', null, true);
  if (data && data.messages) {
    const unread = data.messages.filter(function (m) { return !m.seen; }).length;
    el.textContent = String(unread);
  } else {
    el.textContent = '—';
  }
}

/* ===================== 公告通知 ===================== */

function renderNotices() {
  const admin = isAdmin();
  const rows = CONTENT.notices.map(function (n) {
    return '<tr class="row-click" data-notice="' + n.id + '">' +
      '<td class="notice-title-cell">' + esc(n.title) + '</td>' +
      '<td class="dept-tag">' + esc(n.dept) + '</td>' +
      '<td>' + esc(n.date) + '</td>' +
      '<td>' + (n.pinned ? '<span class="badge-pin">置顶</span>' : '<span class="dim">—</span>') + '</td>' +
      (admin
        ? '<td class="col-actions">' +
            '<button type="button" class="btn btn-sm btn-ghost" data-notice-edit="' + n.id + '" title="编辑公告">✏️ 编辑</button>' +
            '<button type="button" class="btn btn-sm btn-danger" data-notice-del="' + n.id + '" title="删除公告">🗑️ 删除</button>' +
          '</td>'
        : '') +
    '</tr>';
  }).join('');
  $('#content').innerHTML =
    '<div class="page-head page-head-actions"><div><h2>公告通知</h2><p>' +
      (admin ? '可发布、编辑、删除公告；普通账号只能查看' : '查看公司发布的各类公告与通知，点击标题查看详情') +
    '</p></div>' +
      (admin ? '<button type="button" class="btn btn-primary" id="notice-add">＋ 新增公告</button>' : '') +
    '</div>' +
    '<div class="card"><div class="table-wrap"><table class="table">' +
      '<thead><tr><th style="width:' + (admin ? '46%' : '52%') + '">标题</th><th>发布部门</th><th>发布日期</th><th>标记</th>' + (admin ? '<th>操作</th>' : '') + '</tr></thead><tbody>' +
      (rows || '<tr><td colspan="' + (admin ? 5 : 4) + '" class="empty-cell">暂无公告' + (admin ? '，点击右上角「新增公告」发布第一条' : '') + '</td></tr>') +
      '</tbody></table></div></div>';

  if (admin) {
    $('#notice-add').addEventListener('click', function () { openNoticeEditor(null); });
  }
  $('#content').querySelectorAll('[data-notice]').forEach(function (row) {
    row.addEventListener('click', function (ev) {
      if (ev.target.closest('button')) return;
      openNoticeModal(Number(row.dataset.notice));
    });
  });
  $('#content').querySelectorAll('[data-notice-edit]').forEach(function (btn) {
    btn.addEventListener('click', function () {
      const notice = CONTENT.notices.filter(function (n) { return String(n.id) === btn.dataset.noticeEdit; })[0];
      if (notice) openNoticeEditor(notice);
    });
  });
  $('#content').querySelectorAll('[data-notice-del]').forEach(function (btn) {
    btn.addEventListener('click', function () {
      const notice = CONTENT.notices.filter(function (n) { return String(n.id) === btn.dataset.noticeDel; })[0];
      if (!notice) return;
      confirmDelete('公告「' + notice.title + '」', async function () {
        const ok = await contentMutate('notice_delete', { id: notice.id });
        if (ok) renderNotices();
        return ok;
      });
    });
  });
}

function openNoticeModal(id) {
  const notice = CONTENT.notices.filter(function (n) { return String(n.id) === String(id); })[0];
  if (!notice) return;
  const paragraphs = (notice.body && notice.body.length) ? notice.body : ['（暂无正文）'];
  const html =
    '<div class="notice-meta">发布部门：' + esc(notice.dept) + '　·　发布日期：' + esc(notice.date) + (notice.pinned ? '　·　📌 置顶公告' : '') + '</div>' +
    paragraphs.map(function (p) { return '<p>' + esc(p) + '</p>'; }).join('') +
    (isAdmin()
      ? '<div class="modal-actions"><button type="button" class="btn btn-ghost" id="notice-detail-edit">✏️ 编辑</button></div>'
      : '');
  openModal(notice.title, html);
  if (isAdmin()) {
    $('#notice-detail-edit').addEventListener('click', function () { openNoticeEditor(notice); });
  }
}

function openNoticeEditor(notice) {
  const n = notice || { id: 0, title: '', dept: '', date: todayStr(), pinned: 0, body: [] };
  openModal(notice ? '编辑公告' : '新增公告',
    '<form id="notice-form" autocomplete="off">' +
      '<div class="form-field"><label for="nf-title">标题</label><input id="nf-title" type="text" maxlength="100" value="' + esc(n.title) + '" placeholder="请输入公告标题"></div>' +
      '<div class="form-grid">' +
        '<div class="form-field"><label for="nf-dept">发布部门</label><input id="nf-dept" type="text" maxlength="30" value="' + esc(n.dept) + '" placeholder="例如：行政部"></div>' +
        '<div class="form-field"><label for="nf-date">发布日期</label><input id="nf-date" type="date" value="' + esc(n.date) + '"></div>' +
      '</div>' +
      '<div class="form-field"><label for="nf-body">正文</label><textarea id="nf-body" rows="8" placeholder="每行一段，空行会被忽略">' + esc((n.body || []).join('\n')) + '</textarea></div>' +
      '<label class="check-line"><input type="checkbox" id="nf-pinned"' + (n.pinned ? ' checked' : '') + '> 置顶公告</label>' +
      '<div class="modal-actions">' +
        '<button type="button" class="btn btn-ghost" id="notice-cancel">取消</button>' +
        '<button type="submit" class="btn btn-primary">保存</button>' +
      '</div>' +
    '</form>');
  $('#notice-cancel').addEventListener('click', closeModal);
  $('#notice-form').addEventListener('submit', async function (ev) {
    ev.preventDefault();
    const title = $('#nf-title').value.trim();
    const dept = $('#nf-dept').value.trim();
    const date = $('#nf-date').value;
    if (!title) { toast('请填写公告标题', 'error'); return; }
    if (!dept) { toast('请填写发布部门', 'error'); return; }
    if (!date) { toast('请选择发布日期', 'error'); return; }
    const btn = ev.target.querySelector('button[type="submit"]');
    btn.disabled = true;
    btn.textContent = '保存中…';
    const ok = await contentMutate('notice_save', {
      id: n.id || 0,
      title: title,
      dept: dept,
      date: date,
      pinned: $('#nf-pinned').checked ? 1 : 0,
      body: $('#nf-body').value
    });
    btn.disabled = false;
    btn.textContent = '保存';
    if (ok) { closeModal(); renderNotices(); }
  });
}

/* ===================== 流程审批 ===================== */

function renderApprovals() {
  $('#content').innerHTML =
    '<div class="page-head"><h2>流程审批</h2><p>' +
      (isAdmin() ? '处理各类申请流程，点击「通过 / 驳回」即时更新审批状态'
                 : '只读视图：仅管理员可审批，普通账号可查看流程状态') +
    '</p></div>' +
    '<div class="card"><div class="table-wrap"><table class="table">' +
      '<thead><tr><th>申请人</th><th>申请类型</th><th>提交时间</th><th>状态</th><th>操作</th></tr></thead><tbody id="approval-body">' +
      APPROVALS.map(approvalRowHtml).join('') +
      '</tbody></table></div></div>';

  $('#content').querySelectorAll('[data-approve]').forEach(function (btn) {
    btn.addEventListener('click', function () { handleApproval(Number(btn.dataset.approve), btn.dataset.act); });
  });
}

function approvalRowHtml(a) {
  const badge = a.status === '已通过' ? 'badge-ok' : (a.status === '已驳回' ? 'badge-reject' : 'badge-pending');
  const done = a.status !== '待审批';
  return '<tr data-row="' + a.id + '">' +
    '<td>' + esc(a.applicant) + '</td>' +
    '<td><span class="badge badge-pending" style="background:#eef1fe;color:#4f6ef7">' + esc(a.type) + '</span></td>' +
    '<td>' + esc(a.time) + '</td>' +
    '<td><span class="badge ' + badge + '">' + esc(a.status) + '</span></td>' +
    '<td class="col-actions">' +
      '<button class="btn btn-sm btn-success" data-approve="' + a.id + '" data-act="pass"' + (done || !isAdmin() ? ' disabled' : '') + (isAdmin() ? '' : ' title="仅管理员可审批"') + '>通过</button>' +
      '<button class="btn btn-sm btn-danger" data-approve="' + a.id + '" data-act="reject"' + (done || !isAdmin() ? ' disabled' : '') + (isAdmin() ? '' : ' title="仅管理员可审批"') + '>驳回</button>' +
    '</td></tr>';
}

function handleApproval(id, act) {
  if (!isAdmin()) {
    toast('仅管理员可审批', 'error');
    return;
  }
  const item = APPROVALS.filter(function (a) { return a.id === id; })[0];
  if (!item || item.status !== '待审批') return;
  item.status = act === 'pass' ? '已通过' : '已驳回';
  const row = $('#content').querySelector('[data-row="' + id + '"]');
  if (row) row.outerHTML = approvalRowHtml(item);
  $('#content').querySelectorAll('[data-approve]').forEach(function (btn) {
    btn.addEventListener('click', function () { handleApproval(Number(btn.dataset.approve), btn.dataset.act); });
  });
  toast('已' + item.status + '：' + item.applicant + ' 的' + item.type + '申请', 'success');
}

/* ===================== 人事管理 ===================== */

function renderHR() {
  $('#content').innerHTML =
    '<div class="page-head"><h2>人事管理</h2><p>员工花名册，支持按姓名 / 部门快速筛选</p></div>' +
    '<div class="search-bar">🔍 <input id="hr-search" type="text" placeholder="输入姓名或部门进行过滤…"></div>' +
    '<div class="card"><div class="table-wrap"><table class="table">' +
      '<thead><tr><th>工号</th><th>姓名</th><th>部门</th><th>职位</th><th>手机</th><th>邮箱</th><th>入职日期</th></tr></thead>' +
      '<tbody id="hr-body">' + hrRowsHtml(EMPLOYEES) + '</tbody></table></div></div>';

  $('#hr-search').addEventListener('input', function () {
    const keyword = this.value.trim().toLowerCase();
    const list = EMPLOYEES.filter(function (e) {
      return !keyword || e.name.toLowerCase().indexOf(keyword) >= 0 || e.dept.toLowerCase().indexOf(keyword) >= 0;
    });
    $('#hr-body').innerHTML = hrRowsHtml(list);
  });
}

function hrRowsHtml(list) {
  if (!list.length) {
    return '<tr><td colspan="7" style="text-align:center;color:#727a9e;padding:28px">未找到匹配的员工</td></tr>';
  }
  return list.map(function (e) {
    return '<tr>' +
      '<td>' + esc(e.no) + '</td>' +
      '<td><strong>' + esc(e.name) + '</strong></td>' +
      '<td class="dept-tag">' + esc(e.dept) + '</td>' +
      '<td>' + esc(e.title) + '</td>' +
      '<td>' + esc(e.phone) + '</td>' +
      '<td>' + esc(e.email) + '</td>' +
      '<td>' + esc(e.hire) + '</td></tr>';
  }).join('');
}

/* ===================== 日程安排 ===================== */

function groupedSchedule() {
  const groups = [];
  const index = {};
  CONTENT.schedule.forEach(function (item) {
    const key = item.day || '未分组';
    if (!index[key]) {
      index[key] = { day: key, items: [] };
      groups.push(index[key]);
    }
    index[key].items.push(item);
  });
  return groups;
}

function renderSchedule() {
  const admin = isAdmin();
  const groups = groupedSchedule();
  const dayOptions = groups.map(function (g) {
    return '<option value="' + esc(g.day) + '"></option>';
  }).join('');

  const blocks = groups.map(function (g) {
    const items = g.items.map(function (it) {
      return '<div class="agenda-item">' +
        '<div class="agenda-time">' + esc(it.time) + '</div>' +
        '<div class="agenda-main"><div class="agenda-title">' + esc(it.title) + '</div>' +
          (it.place ? '<div class="agenda-place">📍 ' + esc(it.place) + '</div>' : '') +
        '</div>' +
        (admin
          ? '<div class="agenda-actions">' +
              '<button type="button" class="btn btn-sm btn-ghost" data-item-edit="' + it.id + '" title="编辑日程">✏️</button>' +
              '<button type="button" class="btn btn-sm btn-danger" data-item-del="' + it.id + '" title="删除日程">🗑️</button>' +
            '</div>'
          : '') +
      '</div>';
    }).join('');
    return '<div class="day-block">' +
      '<div class="day-head"><div class="day-title">📆 ' + esc(g.day) + '</div>' +
        (admin ? '<button type="button" class="btn btn-sm btn-ghost" data-add-day="' + esc(g.day) + '">＋ 添加日程</button>' : '') +
      '</div>' +
      (items || '<div class="agenda-empty">这一天暂无日程</div>') +
    '</div>';
  }).join('');

  $('#content').innerHTML =
    '<div class="page-head page-head-actions"><div><h2>日程安排</h2><p>' +
      (admin ? '可添加、编辑、删除日程；普通账号只能查看' : '本周工作与活动议程') +
    '</p></div>' +
      (admin ? '<button type="button" class="btn btn-primary" id="schedule-add">＋ 新增日程</button>' : '') +
    '</div>' +
    '<div class="card">' +
      (blocks || '<div class="placeholder-box" style="padding:50px 20px"><div class="ph-icon">📅</div><h3>暂无日程</h3><p>' + (admin ? '点击右上角「新增日程」添加第一条安排。' : '管理员还未添加日程安排。') + '</p></div>') +
    '</div>';

  if (!admin) return;
  $('#schedule-add').addEventListener('click', function () { openScheduleEditor(null, ''); });
  $('#content').querySelectorAll('[data-add-day]').forEach(function (btn) {
    btn.addEventListener('click', function () { openScheduleEditor(null, btn.dataset.addDay); });
  });
  $('#content').querySelectorAll('[data-item-edit]').forEach(function (btn) {
    btn.addEventListener('click', function () {
      const item = CONTENT.schedule.filter(function (it) { return String(it.id) === btn.dataset.itemEdit; })[0];
      if (item) openScheduleEditor(item, item.day);
    });
  });
  $('#content').querySelectorAll('[data-item-del]').forEach(function (btn) {
    btn.addEventListener('click', function () {
      const item = CONTENT.schedule.filter(function (it) { return String(it.id) === btn.dataset.itemDel; })[0];
      if (!item) return;
      confirmDelete('日程「' + item.title + '」', async function () {
        const ok = await contentMutate('schedule_delete', { id: item.id });
        if (ok) renderSchedule();
        return ok;
      });
    });
  });
}

function openScheduleEditor(item, presetDay) {
  const it = item || { id: 0, day: presetDay || '', time: '', title: '', place: '' };
  const dayOptions = groupedSchedule().map(function (g) {
    return '<option value="' + esc(g.day) + '"></option>';
  }).join('');
  openModal(item ? '编辑日程' : '新增日程',
    '<form id="schedule-form" autocomplete="off">' +
      '<div class="form-field"><label for="sf-day">日期 / 星期</label><input id="sf-day" type="text" maxlength="40" list="sf-day-list" value="' + esc(it.day) + '" placeholder="例如：周一（11-09）"><datalist id="sf-day-list">' + dayOptions + '</datalist></div>' +
      '<div class="form-grid">' +
        '<div class="form-field"><label for="sf-time">时间</label><input id="sf-time" type="text" maxlength="40" value="' + esc(it.time) + '" placeholder="例如：09:00-10:00"></div>' +
        '<div class="form-field"><label for="sf-place">地点</label><input id="sf-place" type="text" maxlength="60" value="' + esc(it.place) + '" placeholder="例如：3 楼小会议室"></div>' +
      '</div>' +
      '<div class="form-field"><label for="sf-title">事项</label><input id="sf-title" type="text" maxlength="100" value="' + esc(it.title) + '" placeholder="请输入日程事项"></div>' +
      '<div class="modal-actions">' +
        '<button type="button" class="btn btn-ghost" id="schedule-cancel">取消</button>' +
        '<button type="submit" class="btn btn-primary">保存</button>' +
      '</div>' +
    '</form>');
  $('#schedule-cancel').addEventListener('click', closeModal);
  $('#schedule-form').addEventListener('submit', async function (ev) {
    ev.preventDefault();
    const day = $('#sf-day').value.trim();
    const time = $('#sf-time').value.trim();
    const title = $('#sf-title').value.trim();
    const place = $('#sf-place').value.trim();
    if (!day) { toast('请填写日期或星期', 'error'); return; }
    if (!time) { toast('请填写时间', 'error'); return; }
    if (!title) { toast('请填写日程事项', 'error'); return; }
    const btn = ev.target.querySelector('button[type="submit"]');
    btn.disabled = true;
    btn.textContent = '保存中…';
    const ok = await contentMutate('schedule_save', {
      id: it.id || 0,
      day: day,
      time: time,
      title: title,
      place: place
    });
    btn.disabled = false;
    btn.textContent = '保存';
    if (ok) { closeModal(); renderSchedule(); }
  });
}

/* ===================== 文档中心 ===================== */

const DOC_ICONS = { doc: '📄', xls: '📊', ppt: '📽️', pdf: '📕', txt: '📝', zip: '🗜️' };

function renderDocs() {
  $('#content').innerHTML =
    '<div class="page-head"><h2>文档中心</h2><p>常用制度文件与模板下载（演示数据）</p></div>' +
    '<div class="card"><div class="table-wrap"><table class="table">' +
      '<thead><tr><th style="width:44%">文件名</th><th>类型</th><th>大小</th><th>更新时间</th><th>操作</th></tr></thead><tbody>' +
      DOCS.map(function (d, i) {
        return '<tr>' +
          '<td>' + (DOC_ICONS[d.type] || '📄') + ' ' + esc(d.name) + '</td>' +
          '<td>' + esc(d.type.toUpperCase()) + '</td>' +
          '<td>' + esc(d.size) + '</td>' +
          '<td>' + esc(d.time) + '</td>' +
          '<td class="col-actions"><button class="btn btn-sm btn-primary" data-download="' + i + '">⬇️ 下载</button></td>' +
        '</tr>';
      }).join('') +
      '</tbody></table></div></div>';

  $('#content').querySelectorAll('[data-download]').forEach(function (btn) {
    btn.addEventListener('click', function () { toast('演示系统，下载功能未开放'); });
  });
}

/* ===================== 通讯录 ===================== */

function renderContacts() {
  $('#content').innerHTML =
    '<div class="page-head"><h2>通讯录</h2><p>公司同事联系方式一览</p></div>' +
    '<div class="contact-grid">' +
      CONTACTS.map(function (c, i) {
        return '<div class="contact-card">' +
          '<div class="avatar" style="background:' + AVATAR_COLORS[i % AVATAR_COLORS.length] + '">' + esc(c.name.slice(0, 1)) + '</div>' +
          '<div class="contact-name">' + esc(c.name) + '</div>' +
          '<div class="contact-dept">' + esc(c.dept) + ' · ' + esc(c.title) + '</div>' +
          '<div class="contact-line">📞 ' + esc(c.phone) + '</div>' +
          '<div class="contact-line">✉️ ' + esc(c.email) + '</div>' +
        '</div>';
      }).join('') +
    '</div>';
}

/* ===================== 系统设置（占位） ===================== */

function renderSettings() {
  $('#content').innerHTML =
    '<div class="card"><div class="placeholder-box">' +
      '<div class="ph-icon">⚙️</div>' +
      '<h3>功能建设中，敬请期待</h3>' +
      '<p>系统设置模块正在开发中，后续将提供个人偏好、消息提醒、权限管理等功能。</p>' +
    '</div></div>';
}

/* ===================== 安全防护（内嵌 DDoS 监控面板） ===================== */

function renderSecurity() {
  $('#content').innerHTML =
    '<div class="sec-bar">' +
      '<div class="sec-info">' +
        '<strong>DDoS 流量监控与自动过滤</strong>' +
        '<span class="sec-sub">靶机防护面板已接入 OA：TCP/UDP/HTTP 速率、来源分类、封禁名单、自动屏蔽开关 · 面板每 2 秒自动刷新</span>' +
      '</div>' +
      '<div class="sec-actions">' +
        '<button type="button" class="btn btn-ghost" id="sec-refresh">🔄 刷新</button>' +
        '<a class="btn btn-ghost" href="/ddos/" target="_blank" rel="noopener">↗ 新窗口打开</a>' +
      '</div>' +
    '</div>' +
    '<iframe id="ddos-frame" class="ddos-frame" src="/ddos/?embed=1" title="DDoS 流量监控与自动过滤面板" loading="lazy"></iframe>';

  $('#sec-refresh').addEventListener('click', function () {
    const f = $('#ddos-frame');
    if (f) f.src = '/ddos/?embed=1&t=' + Date.now();
    toast('防护面板已刷新');
  });
}

/* ===================== 邮件模块（真实功能） ===================== */

function renderMail() {
  $('#content').innerHTML = '<div class="card"><div class="placeholder-box"><div class="ph-icon">✉️</div><h3>正在加载邮箱…</h3></div></div>';
  initMail();
}

async function initMail() {
  const me = await mailCall('me', null, true);
  if (me && me.user) {
    MAIL.user = me.user;
    await refreshMailList(true);
    paintMail();
  } else {
    MAIL.user = null;
    MAIL.messages = [];
    MAIL.selected = null;
    paintMailLogin();
  }
}

function paintMailLogin() {
  const prefill = OA.user || '';
  $('#content').innerHTML =
    '<div class="page-head"><h2>邮件</h2><p>内网邮件系统 · 请先登录邮箱</p></div>' +
    '<div class="mail-login-wrap"><div class="mail-login-card">' +
      '<h3>📮 邮箱登录</h3>' +
      '<div class="mail-login-hint">💡 使用邮箱账号登录：eva@ddzt.old / rei、kk@ddzt.old / zmjjkk、admin@ddzt.old / admin<br>登录 OA 后进入邮件会自动关联，无需再次登录</div>' +
      '<form id="mail-login-form" autocomplete="off">' +
        '<div class="form-field"><label for="mail-user">邮箱账号</label><input id="mail-user" type="text" placeholder="例如：eva@ddzt.old" value="' + esc(prefill) + '"></div>' +
        '<div class="form-field"><label for="mail-pass">密码</label><input id="mail-pass" type="password" placeholder="请输入密码"></div>' +
        '<button type="submit" class="btn btn-primary btn-block">登录邮箱</button>' +
      '</form>' +
    '</div></div>';

  $('#mail-login-form').addEventListener('submit', async function (ev) {
    ev.preventDefault();
    const username = $('#mail-user').value.trim();
    const password = $('#mail-pass').value;
    if (!username || !password) { toast('请输入邮箱账号和密码', 'error'); return; }
    const data = await mailCall('login', { username: username, password: password });
    if (!data) return;
    MAIL.user = data.user;
    toast('邮箱登录成功：' + data.user, 'success');
    await refreshMailList(true);
    paintMail();
  });
}

function formatSize(bytes) {
  const n = Number(bytes) || 0;
  if (n <= 0) return '0 B';
  if (n < 1024) return n + ' B';
  if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
  if (n < 1024 * 1024 * 1024) return (n / (1024 * 1024)).toFixed(1) + ' MB';
  return (n / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
}

function mailAttachmentUrl(folder, uid, part) {
  return 'api/mail.php?action=attachment&folder=' + encodeURIComponent(folder || 'INBOX') +
    '&uid=' + encodeURIComponent(uid) + '&part=' + encodeURIComponent(part);
}

function mailRowHtml(m) {
  const active = MAIL.selected && String(MAIL.selected.uid) === String(m.uid) ? ' active' : '';
  const unreadCls = (MAIL.folder === 'INBOX' && !m.seen) ? ' unread' : '';
  const who = MAIL.folder === 'Sent' ? ('发给 ' + (m.to || m.to_addr || '')) : m.from;
  const clip = m.has_attachment
    ? '<span class="m-att" title="含 ' + (m.attachment_count || 1) + ' 个附件">📎</span>'
    : '';
  return '<div class="mail-row' + active + unreadCls + '" data-uid="' + esc(m.uid) + '">' +
    '<span class="dot' + (m.seen ? ' read' : '') + '"></span>' +
    '<div class="m-main">' +
      '<div class="m-from"><span>' + esc(who) + '</span><span class="m-date">' + esc(m.date) + '</span></div>' +
      '<div class="m-subject">' + clip + esc(m.subject) + '</div>' +
      '<div class="m-snippet">' + esc(m.snippet) + '</div>' +
    '</div></div>';
}

function paintMail() {
  const isSent = MAIL.folder === 'Sent';
  let readHtml;
  if (MAIL.selected) {
    const sel = MAIL.selected;
    const atts = sel.attachments || [];
    let attHtml = '';
    if (atts.length) {
      attHtml = '<div class="mail-attachments"><div class="att-title">📎 附件（' + atts.length + '）</div>' +
        atts.map(function (a) {
          return '<a class="att-item" href="' + mailAttachmentUrl(sel.folder || MAIL.folder, sel.uid, a.part) + '" download>' +
            '<span class="att-icon">📄</span>' +
            '<span class="att-name">' + esc(a.filename) + '</span>' +
            '<span class="att-size">' + formatSize(a.size) + '</span>' +
            '<span class="att-dl">下载</span></a>';
        }).join('') +
        '</div>';
    }
    readHtml =
      '<div class="mail-read">' +
        '<h3>' + esc(sel.subject) + '</h3>' +
        '<div class="mail-meta">' +
          '<div><strong>发件人：</strong>' + esc(sel.from) + ' &lt;' + esc(sel.from_addr) + '&gt;</div>' +
          '<div><strong>收件人：</strong>' + esc(sel.to) + '</div>' +
          '<div><strong>时　间：</strong>' + esc(sel.date) + '</div>' +
        '</div>' +
        '<div class="mail-body-text">' + esc(sel.body_text) + '</div>' +
        attHtml +
        '<div class="mail-read-actions"><button class="btn btn-danger" id="mail-delete-btn">🗑️ 删除</button></div>' +
      '</div>';
  } else {
    readHtml = '<div class="mail-empty"><div class="e-icon">📭</div><div>' +
      (isSent ? '选择上方已发送邮件查看' : '选择左侧邮件进行阅读') + '</div></div>';
  }

  const counts = MAIL.counts || { INBOX: 0, Sent: 0 };
  $('#content').innerHTML =
    '<div class="mail-toolbar">' +
      '<button class="btn btn-primary" id="mail-compose-btn">✍️ 写信</button>' +
      '<button class="btn btn-ghost" id="mail-refresh-btn">🔄 刷新</button>' +
      '<button class="btn btn-ghost" id="mail-logout-btn">🚪 退出</button>' +
      '<span class="mail-user-tag">当前邮箱：' + esc(MAIL.user) + '</span>' +
    '</div>' +
    '<div class="mail-layout">' +
      '<div class="mail-pane mail-folders">' +
        '<div class="folder-item' + (isSent ? '' : ' active') + '" data-folder="INBOX">' +
          '<span>📥 收件箱</span><span class="folder-count">' + (counts.INBOX || 0) + '</span></div>' +
        '<div class="folder-item' + (isSent ? ' active' : '') + '" data-folder="Sent">' +
          '<span>📤 已发送</span><span class="folder-count">' + (counts.Sent || 0) + '</span></div>' +
      '</div>' +
      '<div class="mail-pane mail-list" id="mail-list-pane">' +
        (MAIL.messages.length
          ? MAIL.messages.map(mailRowHtml).join('')
          : '<div class="mail-empty"><div class="e-icon">📭</div><div>' +
            (isSent ? '已发送箱暂无邮件' : '收件箱暂无邮件') + '</div></div>') +
      '</div>' +
      '<div class="mail-pane" id="mail-read-pane">' + readHtml + '</div>' +
    '</div>';

  $('#content').querySelectorAll('.mail-row').forEach(function (row) {
    row.addEventListener('click', function () { openMail(row.dataset.uid); });
  });
  $('#content').querySelectorAll('.folder-item').forEach(function (item) {
    item.addEventListener('click', async function () {
      const folder = item.dataset.folder;
      if (folder === MAIL.folder) return;
      const previous = MAIL.folder;
      MAIL.folder = folder;
      MAIL.selected = null;
      const ok = await refreshMailList(true);
      if (!ok) MAIL.folder = previous;
      paintMail();
    });
  });
  $('#mail-compose-btn').addEventListener('click', openComposeModal);
  $('#mail-refresh-btn').addEventListener('click', async function () {
    const ok = await refreshMailList();
    paintMail();
    if (ok) toast(MAIL.folder === 'Sent' ? '已发送箱已刷新' : '收件箱已刷新', 'success');
  });
  $('#mail-logout-btn').addEventListener('click', async function () {
    await mailCall('logout');
    MAIL.user = null;
    MAIL.messages = [];
    MAIL.selected = null;
    MAIL.folder = 'INBOX';
    MAIL.counts = { INBOX: 0, Sent: 0 };
    toast('已退出邮箱登录', 'success');
    paintMailLogin();
  });
  const delBtn = $('#mail-delete-btn');
  if (delBtn) {
    delBtn.addEventListener('click', async function () {
      if (!MAIL.selected) return;
      const data = await mailCall('delete', { uid: MAIL.selected.uid, folder: MAIL.folder });
      if (!data) return;
      toast(data.message || '已删除', 'success');
      MAIL.selected = null;
      await refreshMailList(true);
      paintMail();
    });
  }
}

async function openMail(uid) {
  const folder = MAIL.folder;
  const data = await mailCall('read', { uid: uid, folder: folder });
  if (!data) return;
  data.folder = data.folder || folder;
  MAIL.selected = data;
  const row = MAIL.messages.filter(function (m) { return String(m.uid) === String(uid); })[0];
  if (row) row.seen = true;
  paintMail();
}

function openComposeModal() {
  const picked = [];

  openModal('写信',
    '<form id="compose-form" autocomplete="off">' +
      '<div class="form-field"><label for="compose-to">收件人</label>' +
        '<input id="compose-to" type="text" list="mail-address-list" placeholder="请选择或输入收件人">' +
        '<datalist id="mail-address-list">' +
          '<option value="eva@ddzt.old"></option>' +
          '<option value="kk@ddzt.old"></option>' +
        '</datalist>' +
      '</div>' +
      '<div class="form-field"><label for="compose-subject">主题</label><input id="compose-subject" type="text" placeholder="请输入邮件主题"></div>' +
      '<div class="form-field"><label for="compose-body">正文</label><textarea id="compose-body" rows="7" placeholder="请输入邮件正文…"></textarea></div>' +
      '<div class="form-field"><label>附件</label>' +
        '<div class="att-pick-row">' +
          '<label class="btn btn-ghost btn-sm att-pick-btn" for="compose-files">📎 添加附件</label>' +
          '<span class="att-pick-hint">单个 ≤20MB，合计 ≤20MB，最多 10 个</span>' +
        '</div>' +
        '<input id="compose-files" type="file" multiple hidden>' +
        '<div id="compose-file-list" class="att-pick-list"></div>' +
      '</div>' +
      '<div class="modal-actions">' +
        '<button type="button" class="btn btn-ghost" id="compose-cancel">取消</button>' +
        '<button type="submit" class="btn btn-primary">发送</button>' +
      '</div>' +
    '</form>');

  function totalSize() {
    return picked.reduce(function (sum, f) { return sum + f.size; }, 0);
  }

  function renderPicked() {
    const box = $('#compose-file-list');
    if (!picked.length) { box.innerHTML = ''; return; }
    box.innerHTML = picked.map(function (f, i) {
      return '<div class="att-pick-item">' +
        '<span class="att-pick-name">📄 ' + esc(f.name) + '</span>' +
        '<span class="att-pick-size">' + formatSize(f.size) + '</span>' +
        '<button type="button" class="att-remove" data-idx="' + i + '" title="移除">×</button>' +
      '</div>';
    }).join('');
    box.querySelectorAll('.att-remove').forEach(function (btn) {
      btn.addEventListener('click', function () {
        picked.splice(Number(btn.dataset.idx), 1);
        renderPicked();
      });
    });
  }

  $('#compose-files').addEventListener('change', function (ev) {
    const files = Array.prototype.slice.call(ev.target.files || []);
    for (let i = 0; i < files.length; i++) {
      const f = files[i];
      if (picked.length >= MAIL_MAX_FILES) {
        toast('最多添加 ' + MAIL_MAX_FILES + ' 个附件', 'error');
        break;
      }
      if (!f.size) { toast('已跳过空文件：' + f.name, 'error'); continue; }
      if (f.size > MAIL_MAX_BYTES) { toast('附件超过 20MB：' + f.name, 'error'); continue; }
      if (totalSize() + f.size > MAIL_MAX_BYTES) { toast('全部附件合计不能超过 20MB', 'error'); break; }
      const dup = picked.some(function (p) {
        return p.name === f.name && p.size === f.size && p.lastModified === f.lastModified;
      });
      if (dup) continue;
      picked.push(f);
    }
    ev.target.value = '';   /* 清空后才能再次选择同一个文件 */
    renderPicked();
  });

  $('#compose-cancel').addEventListener('click', closeModal);
  $('#compose-form').addEventListener('submit', async function (ev) {
    ev.preventDefault();
    const to = $('#compose-to').value.trim();
    const subject = $('#compose-subject').value.trim();
    const body = $('#compose-body').value;
    if (!to || !subject) { toast('请填写收件人和主题', 'error'); return; }
    const btn = ev.target.querySelector('button[type="submit"]');
    if (btn) { btn.disabled = true; btn.textContent = '发送中…'; }
    const result = await mailApi('send', { to: to, subject: subject, body: body }, picked);
    if (btn) { btn.disabled = false; btn.textContent = '发送'; }
    if (!result || result.ok !== true) {
      toast((result && result.error) ? result.error : '发送失败，请稍后重试', 'error');
      return;
    }
    const data = result.data || {};
    if (data.saved === false) {
      toast('邮件已发送，但存入「已发送」失败，可能无法在发件箱查看', 'error');
    } else {
      toast(data.message || '邮件已发送', 'success');
    }
    closeModal();
    await refreshMailList(true);
    paintMail();
  });
}

/* ===================== 路由 ===================== */

const ROUTES = {
  dashboard: { title: '工作台', render: renderDashboard },
  notices: { title: '公告通知', render: renderNotices },
  approvals: { title: '流程审批', render: renderApprovals },
  hr: { title: '人事管理', render: renderHR },
  schedule: { title: '日程安排', render: renderSchedule },
  docs: { title: '文档中心', render: renderDocs },
  contacts: { title: '通讯录', render: renderContacts },
  mail: { title: '邮件', render: renderMail },
  security: { title: '安全防护 · DDoS 监控', render: renderSecurity },
  settings: { title: '系统设置', render: renderSettings }
};

function currentRoute() {
  const key = location.hash.replace(/^#\/?/, '');
  return ROUTES[key] ? key : 'dashboard';
}

function navigate() {
  const key = currentRoute();
  document.querySelectorAll('#sidebar-nav .nav-item').forEach(function (a) {
    a.classList.toggle('active', a.dataset.route === key);
  });
  $('#topbar-title').textContent = ROUTES[key].title;
  window.scrollTo(0, 0);
  ROUTES[key].render();
}

/* ===================== 启动 ===================== */

(async function boot() {
  /* 以服务端会话为准：刷新页面后仍保持登录 */
  const me = await oaApi('me');
  if (me.ok) {
    await enterApp(me.data.user, me.data.role);
  } else {
    sessionStorage.removeItem('oa_user');
  }

  $('#login-form').addEventListener('submit', async function (ev) {
    ev.preventDefault();
    const user = $('#login-user').value.trim().toLowerCase();
    const pass = $('#login-pass').value;
    if (!user || !pass) {
      toast('请输入邮箱账号和密码');
      return;
    }
    const btn = ev.target.querySelector('button[type="submit"]');
    btn.disabled = true;
    btn.textContent = '登录中…';
    const res = await oaApi('login', { username: user, password: pass });
    btn.disabled = false;
    btn.textContent = '登 录';
    if (!res.ok) {
      toast(res.error || '登录失败', 'error');
      $('#login-pass').value = '';
      $('#login-pass').focus();
      return;
    }
    toast('登录成功，欢迎回来，' + res.data.user, 'success');
    await enterApp(res.data.user, res.data.role);
  });

  $('#logout-btn').addEventListener('click', async function () {
    await oaApi('logout');
    toast('已退出登录');
    exitApp();
  });

  $('#modal-close').addEventListener('click', closeModal);
  $('#modal-mask').addEventListener('click', closeModal);

  window.addEventListener('hashchange', function () {
    if (OA.user) navigate();
  });
})();
