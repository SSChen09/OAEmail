'use strict';

/* ============================================================
   ddzt.old 协同办公 OA —— 演示展示版前端逻辑
   除邮件模块外全部为写死的演示数据；邮件模块对接 api/mail.php
   ============================================================ */

/* ===================== 演示数据（集中定义，方便替换） ===================== */

const DEMO_STATS = { todos: 8, notices: 5, attendance: 22 };

const NOTICES = [
  {
    id: 1,
    title: '关于召开 2026 年度工作总结大会的通知',
    dept: '行政部',
    date: '2026-11-10',
    pinned: true,
    body: [
      '各部门、各科室：',
      '为全面总结 2026 年度各项工作开展情况，谋划 2027 年重点任务，经研究决定，召开 2026 年度工作总结大会。现将有关事项通知如下：',
      '一、会议时间：2026 年 11 月 20 日（星期五）09:00—12:00；二、会议地点：总部三楼多功能报告厅；三、参会人员：全体正式员工。',
      '请各部门提前准备本部门年度工作总结（PPT，限时 8 分钟），并于 11 月 17 日前将电子版报送行政部邮箱。会议期间请将手机调至静音，准时出席，不得无故缺席。'
    ]
  },
  {
    id: 2,
    title: '关于加强内网信息系统安全保密管理的通知',
    dept: '信息中心',
    date: '2026-11-08',
    pinned: true,
    body: [
      '全体同仁：',
      '近期安全巡检发现部分终端存在弱口令、未及时安装补丁等问题，为保障内网信息系统安全稳定运行，现就安全保密管理要求重申如下：',
      '一、严禁将内网文件通过任何方式外传；二、账号口令须包含大小写字母与数字，长度不少于 8 位，每 90 天更换一次；三、发现可疑邮件、可疑链接请勿点击，第一时间上报信息中心。',
      '信息中心将开展为期两周的专项检查，请各部门予以配合。'
    ]
  },
  {
    id: 3,
    title: '2026 年 11 月员工生日会活动安排',
    dept: '工会',
    date: '2026-11-06',
    pinned: false,
    body: [
      '各位同事：',
      '为丰富员工文化生活，增强团队凝聚力，工会将举办 11 月员工生日会。',
      '活动时间：11 月 13 日（星期五）16:00；活动地点：员工活动中心；活动内容：生日蛋糕、茶歇、互动游戏、礼品发放。',
      '请 11 月生日的同事准时参加，也欢迎其他同事到场同乐。'
    ]
  },
  {
    id: 4,
    title: '关于 2026 年度职工健康体检的通知',
    dept: '人力资源部',
    date: '2026-11-03',
    pinned: false,
    body: [
      '全体正式员工：',
      '公司统一组织 2026 年度职工健康体检，现将有关事项通知如下：',
      '一、体检时间：11 月 16 日至 11 月 27 日（工作日 07:30—10:30）；二、体检地点：市第一人民医院健康管理中心；三、注意事项：体检当日须空腹，携带本人身份证。',
      '请各部门统计本部门参检人员名单，于 11 月 5 日前报送人力资源部。'
    ]
  },
  {
    id: 5,
    title: '关于办公区冬季供暖及节能管理的通知',
    dept: '行政部',
    date: '2026-10-30',
    pinned: false,
    body: [
      '各部门：',
      '冬季供暖将于 11 月 1 日正式开始，办公区空调温度统一设置为 20℃，请勿自行调节。',
      '下班后请关闭电脑、打印机、饮水机等用电设备，最后离开办公区的同事负责关闭照明与门窗。',
      '行政部将每周开展节能巡查，并在公告栏通报检查情况。'
    ]
  },
  {
    id: 6,
    title: '关于开展第四季度业务技能培训的通知',
    dept: '培训中心',
    date: '2026-10-27',
    pinned: false,
    body: [
      '各部门：',
      '为提升员工专业技能水平，培训中心定于第四季度开展系列业务技能培训。',
      '培训内容：公文写作规范、数据报表分析、内网系统操作实务、沟通与协作技巧。培训形式：线下授课 + 上机实操，每期半天。',
      '请各部门根据工作实际组织报名，报名截止时间 10 月 31 日。'
    ]
  }
];

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

const SCHEDULE = [
  {
    day: '周一（11-09）',
    items: [
      { time: '09:00-10:00', title: '部门周例会', place: '3 楼小会议室' },
      { time: '14:00-15:30', title: '新员工入职培训（第二期）', place: '培训中心 201' },
      { time: '16:00-17:00', title: '内网系统巡检结果评审', place: '技术部办公区' }
    ]
  },
  {
    day: '周二（11-10）',
    items: [
      { time: '10:00-11:30', title: '年度预算编制沟通会', place: '财务部会议室' },
      { time: '15:00-16:00', title: '供应商合同用章审批', place: '行政部办公室' }
    ]
  },
  {
    day: '周三（11-11）',
    items: [
      { time: '09:30-10:30', title: '信息安全保密宣讲', place: '三楼多功能报告厅' },
      { time: '13:30-15:00', title: '办公区消防演练', place: '总部大楼 A 座' },
      { time: '16:30-17:30', title: '项目进度汇报（协同办公平台）', place: '技术部会议室' }
    ]
  },
  {
    day: '周四（11-12）',
    items: [
      { time: '09:00-12:00', title: '季度绩效面谈（行政部）', place: '2 楼洽谈室 A' },
      { time: '14:00-15:00', title: '11 月生日会筹备会', place: '员工活动中心' }
    ]
  },
  {
    day: '周五（11-13）',
    items: [
      { time: '10:00-11:00', title: '月度经营分析会', place: '总经理会议室' },
      { time: '16:00-18:00', title: '11 月员工生日会', place: '员工活动中心' }
    ]
  },
  {
    day: '周六（11-14）',
    items: [
      { time: '09:30-11:30', title: '羽毛球协会活动', place: '市体育馆 3 号场' }
    ]
  },
  {
    day: '周日（11-15）',
    items: [
      { time: '10:00-11:00', title: '下周工作计划整理', place: '线上 / 工位' },
      { time: '15:00-16:30', title: '读书分享会（第七期）', place: '员工书吧' }
    ]
  }
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

/* ===================== 登录 / 登出（纯前端演示） ===================== */

function enterApp(user) {
  $('#current-user').textContent = user;
  $('#login-page').classList.add('hidden');
  $('#app').classList.remove('hidden');
  if (!location.hash) location.hash = '#/dashboard';
  navigate();
}

function exitApp() {
  sessionStorage.removeItem('oa_user');
  $('#app').classList.add('hidden');
  $('#login-page').classList.remove('hidden');
  $('#login-form').reset();
}

/* ===================== 邮件 API 封装（真实功能） ===================== */

const MAIL = { user: null, messages: [], selected: null };

async function mailApi(action, params) {
  const body = new URLSearchParams();
  body.append('action', action);
  if (params) {
    Object.keys(params).forEach(function (key) {
      body.append(key, params[key]);
    });
  }
  try {
    const res = await fetch('api/mail.php', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      credentials: 'same-origin',
      body: body.toString()
    });
    return await res.json();
  } catch (err) {
    return { ok: false, error: '请求失败，无法连接邮件服务' };
  }
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

async function refreshMailList(silent) {
  const data = await mailCall('list', null, silent);
  if (data && data.messages) {
    MAIL.messages = data.messages;
    return true;
  }
  return false;
}

/* ===================== 工作台 ===================== */

function renderDashboard() {
  $('#content').innerHTML =
    '<div class="stat-grid">' +
      '<div class="stat-card"><div class="stat-icon i-blue">📋</div><div><div class="stat-num">' + DEMO_STATS.todos + '</div><div class="stat-label">待办事项</div></div></div>' +
      '<div class="stat-card"><div class="stat-icon i-purple">📢</div><div><div class="stat-num">' + DEMO_STATS.notices + '</div><div class="stat-label">公告通知</div></div></div>' +
      '<div class="stat-card"><div class="stat-icon i-green">🗓️</div><div><div class="stat-num">' + DEMO_STATS.attendance + ' 天</div><div class="stat-label">本月考勤</div></div></div>' +
      '<div class="stat-card"><div class="stat-icon i-orange">✉️</div><div><div class="stat-num" id="stat-unread">—</div><div class="stat-label">未读邮件</div></div></div>' +
    '</div>' +
    '<div class="card"><div class="card-title">🚀 快捷入口</div><div class="quick-grid">' +
      QUICK_LINKS.map(function (item) {
        return '<a class="quick-item" href="' + item.route + '"><span class="q-icon">' + item.icon + '</span><span class="q-label">' + item.label + '</span></a>';
      }).join('') +
    '</div></div>' +
    '<div class="card"><div class="card-title">📢 最新公告<span class="more" id="more-notices">查看全部 &gt;</span></div>' +
      NOTICES.slice(0, 3).map(function (n) {
        return '<div class="todo-item row-click" data-notice="' + n.id + '"><span>' + (n.pinned ? '📌' : '📄') + '</span><span class="todo-text">' + esc(n.title) + (n.pinned ? '<span class="badge-pin">置顶</span>' : '') + '</span><span class="todo-date">' + esc(n.date) + '</span></div>';
      }).join('') +
    '</div>' +
    '<div class="card"><div class="card-title">✅ 我的待办清单</div><div id="todo-list">' +
      TODOS.map(function (t) {
        return '<label class="todo-item' + (t.done ? ' done' : '') + '" data-todo="' + t.id + '">' +
          '<input type="checkbox"' + (t.done ? ' checked' : '') + '>' +
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
    box.addEventListener('change', function () {
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
  $('#content').innerHTML =
    '<div class="page-head"><h2>公告通知</h2><p>查看公司发布的各类公告与通知，点击标题查看详情</p></div>' +
    '<div class="card"><div class="table-wrap"><table class="table">' +
      '<thead><tr><th style="width:52%">标题</th><th>发布部门</th><th>发布日期</th><th>标记</th></tr></thead><tbody>' +
      NOTICES.map(function (n) {
        return '<tr class="row-click" data-notice="' + n.id + '">' +
          '<td class="notice-title-cell">' + esc(n.title) + '</td>' +
          '<td class="dept-tag">' + esc(n.dept) + '</td>' +
          '<td>' + esc(n.date) + '</td>' +
          '<td>' + (n.pinned ? '<span class="badge-pin">置顶</span>' : '<span style="color:#aab;margin-left:8px">—</span>') + '</td>' +
        '</tr>';
      }).join('') +
      '</tbody></table></div></div>';

  $('#content').querySelectorAll('[data-notice]').forEach(function (row) {
    row.addEventListener('click', function () { openNoticeModal(Number(row.dataset.notice)); });
  });
}

function openNoticeModal(id) {
  const notice = NOTICES.filter(function (n) { return n.id === id; })[0];
  if (!notice) return;
  const html =
    '<div class="notice-meta">发布部门：' + esc(notice.dept) + '　·　发布日期：' + esc(notice.date) + (notice.pinned ? '　·　📌 置顶公告' : '') + '</div>' +
    notice.body.map(function (p) { return '<p>' + esc(p) + '</p>'; }).join('');
  openModal(notice.title, html);
}

/* ===================== 流程审批 ===================== */

function renderApprovals() {
  $('#content').innerHTML =
    '<div class="page-head"><h2>流程审批</h2><p>处理各类申请流程，点击「通过 / 驳回」即时更新审批状态</p></div>' +
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
      '<button class="btn btn-sm btn-success" data-approve="' + a.id + '" data-act="pass"' + (done ? ' disabled' : '') + '>通过</button>' +
      '<button class="btn btn-sm btn-danger" data-approve="' + a.id + '" data-act="reject"' + (done ? ' disabled' : '') + '>驳回</button>' +
    '</td></tr>';
}

function handleApproval(id, act) {
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

function renderSchedule() {
  $('#content').innerHTML =
    '<div class="page-head"><h2>日程安排</h2><p>本周（11-09 至 11-15）工作与活动议程</p></div>' +
    '<div class="card">' +
      SCHEDULE.map(function (d) {
        return '<div class="day-block"><div class="day-title">📆 ' + esc(d.day) + '</div>' +
          d.items.map(function (it) {
            return '<div class="agenda-item"><div class="agenda-time">' + esc(it.time) + '</div>' +
              '<div><div class="agenda-title">' + esc(it.title) + '</div><div class="agenda-place">📍 ' + esc(it.place) + '</div></div></div>';
          }).join('') +
        '</div>';
      }).join('') +
    '</div>';
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
  $('#content').innerHTML =
    '<div class="page-head"><h2>邮件</h2><p>内网邮件系统 · 请先登录邮箱</p></div>' +
    '<div class="mail-login-wrap"><div class="mail-login-card">' +
      '<h3>📮 邮箱登录</h3>' +
      '<div class="mail-login-hint">💡 演示账号：eva@ddzt.old 或 kk@ddzt.old<br>密码分别是 eva 和 kk</div>' +
      '<form id="mail-login-form" autocomplete="off">' +
        '<div class="form-field"><label for="mail-user">邮箱账号</label><input id="mail-user" type="text" placeholder="例如：eva@ddzt.old"></div>' +
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

function mailRowHtml(m) {
  const active = MAIL.selected && String(MAIL.selected.uid) === String(m.uid) ? ' active' : '';
  const unreadCls = m.seen ? '' : ' unread';
  return '<div class="mail-row' + active + unreadCls + '" data-uid="' + esc(m.uid) + '">' +
    '<span class="dot' + (m.seen ? ' read' : '') + '"></span>' +
    '<div class="m-main">' +
      '<div class="m-from"><span>' + esc(m.from) + '</span><span class="m-date">' + esc(m.date) + '</span></div>' +
      '<div class="m-subject">' + esc(m.subject) + '</div>' +
      '<div class="m-snippet">' + esc(m.snippet) + '</div>' +
    '</div></div>';
}

function paintMail() {
  const readHtml = MAIL.selected ?
    '<div class="mail-read">' +
      '<h3>' + esc(MAIL.selected.subject) + '</h3>' +
      '<div class="mail-meta">' +
        '<div><strong>发件人：</strong>' + esc(MAIL.selected.from) + ' &lt;' + esc(MAIL.selected.from_addr) + '&gt;</div>' +
        '<div><strong>收件人：</strong>' + esc(MAIL.selected.to) + '</div>' +
        '<div><strong>时　间：</strong>' + esc(MAIL.selected.date) + '</div>' +
      '</div>' +
      '<div class="mail-body-text">' + esc(MAIL.selected.body_text) + '</div>' +
      '<div class="mail-read-actions"><button class="btn btn-danger" id="mail-delete-btn">🗑️ 删除</button></div>' +
    '</div>' :
    '<div class="mail-empty"><div class="e-icon">📭</div><div>选择左侧邮件进行阅读</div></div>';

  $('#content').innerHTML =
    '<div class="mail-toolbar">' +
      '<button class="btn btn-primary" id="mail-compose-btn">✍️ 写信</button>' +
      '<button class="btn btn-ghost" id="mail-inbox-btn">📥 收件箱</button>' +
      '<button class="btn btn-ghost" id="mail-refresh-btn">🔄 刷新</button>' +
      '<button class="btn btn-ghost" id="mail-logout-btn">🚪 退出</button>' +
      '<span class="mail-user-tag">当前邮箱：' + esc(MAIL.user) + '</span>' +
    '</div>' +
    '<div class="mail-layout">' +
      '<div class="mail-pane mail-folders">' +
        '<div class="folder-item active"><span>📥 收件箱 INBOX</span><span class="folder-count">' + MAIL.messages.length + '</span></div>' +
      '</div>' +
      '<div class="mail-pane mail-list" id="mail-list-pane">' +
        (MAIL.messages.length ? MAIL.messages.map(mailRowHtml).join('') : '<div class="mail-empty"><div class="e-icon">📭</div><div>收件箱暂无邮件</div></div>') +
      '</div>' +
      '<div class="mail-pane" id="mail-read-pane">' + readHtml + '</div>' +
    '</div>';

  $('#content').querySelectorAll('.mail-row').forEach(function (row) {
    row.addEventListener('click', function () { openMail(row.dataset.uid); });
  });
  $('#mail-compose-btn').addEventListener('click', openComposeModal);
  $('#mail-inbox-btn').addEventListener('click', async function () {
    MAIL.selected = null;
    await refreshMailList();
    paintMail();
  });
  $('#mail-refresh-btn').addEventListener('click', async function () {
    await refreshMailList();
    paintMail();
    toast('收件箱已刷新', 'success');
  });
  $('#mail-logout-btn').addEventListener('click', async function () {
    await mailCall('logout');
    MAIL.user = null;
    MAIL.messages = [];
    MAIL.selected = null;
    toast('已退出邮箱登录', 'success');
    paintMailLogin();
  });
  const delBtn = $('#mail-delete-btn');
  if (delBtn) {
    delBtn.addEventListener('click', async function () {
      if (!MAIL.selected) return;
      const data = await mailCall('delete', { uid: MAIL.selected.uid });
      if (!data) return;
      toast(data.message || '已删除', 'success');
      MAIL.selected = null;
      await refreshMailList(true);
      paintMail();
    });
  }
}

async function openMail(uid) {
  const data = await mailCall('read', { uid: uid });
  if (!data) return;
  MAIL.selected = data;
  const row = MAIL.messages.filter(function (m) { return String(m.uid) === String(uid); })[0];
  if (row) row.seen = true;
  paintMail();
}

function openComposeModal() {
  openModal('写邮件',
    '<form id="compose-form" autocomplete="off">' +
      '<div class="form-field"><label for="compose-to">收件人</label>' +
        '<input id="compose-to" type="text" list="mail-address-list" placeholder="请选择或输入收件人">' +
        '<datalist id="mail-address-list">' +
          '<option value="eva@ddzt.old"></option>' +
          '<option value="kk@ddzt.old"></option>' +
        '</datalist>' +
      '</div>' +
      '<div class="form-field"><label for="compose-subject">主题</label><input id="compose-subject" type="text" placeholder="请输入邮件主题"></div>' +
      '<div class="form-field"><label for="compose-body">正文</label><textarea id="compose-body" rows="8" placeholder="请输入邮件正文…"></textarea></div>' +
      '<div class="modal-actions">' +
        '<button type="button" class="btn btn-ghost" id="compose-cancel">取消</button>' +
        '<button type="submit" class="btn btn-primary">发送</button>' +
      '</div>' +
    '</form>');

  $('#compose-cancel').addEventListener('click', closeModal);
  $('#compose-form').addEventListener('submit', async function (ev) {
    ev.preventDefault();
    const to = $('#compose-to').value.trim();
    const subject = $('#compose-subject').value.trim();
    const body = $('#compose-body').value;
    if (!to || !subject) { toast('请填写收件人和主题', 'error'); return; }
    const data = await mailCall('send', { to: to, subject: subject, body: body });
    if (!data) return;
    toast(data.message || '邮件已发送', 'success');
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

(function boot() {
  const savedUser = sessionStorage.getItem('oa_user');
  if (savedUser) enterApp(savedUser);

  $('#login-form').addEventListener('submit', function (ev) {
    ev.preventDefault();
    const user = $('#login-user').value.trim() || 'admin';
    sessionStorage.setItem('oa_user', user);
    toast('登录成功，欢迎回来，' + user, 'success');
    enterApp(user);
  });

  $('#logout-btn').addEventListener('click', function () {
    toast('已退出登录');
    exitApp();
  });

  $('#modal-close').addEventListener('click', closeModal);
  $('#modal-mask').addEventListener('click', closeModal);

  window.addEventListener('hashchange', function () {
    if (sessionStorage.getItem('oa_user')) navigate();
  });
})();
