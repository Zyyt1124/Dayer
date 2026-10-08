#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 Dayer 开题答辩 PPT（11 页正文 + 1 页备用答疑）。

设计原则（对应《开题报告PPT制作思路.md》）：
  1. 全场不谈进度，时态一律用「将 / 拟 / 本项目的做法是」
  2. 创新点每页落到「别人怎么做 vs 我们怎么做」的一句话对比
  3. 页面上不放段落，数字 / 对比表 / 色块为主

运行：  py -3.13 build_ppt.py <输出路径.pptx>
"""
import sys
from pptx import Presentation
from pptx.util import Inches, Pt
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
from pptx.enum.shapes import MSO_SHAPE
from pptx.oxml.ns import qn

# ---------------------------------------------------------------- 视觉系统
# 简约配色：一个墨色 + 一个强调蓝 + 一个提醒橙，其余全部走中性灰。
# 分组靠统一的极浅灰底和留白，不靠彩色底纹和色条 —— 颜色只用来标「重点」。
FONT = '微软雅黑'
INK    = RGBColor(0x1F, 0x24, 0x2B)   # 标题、需要被记住的字
TEXT   = RGBColor(0x3C, 0x42, 0x4A)   # 正文
MUTED  = RGBColor(0x8B, 0x93, 0x9D)   # 次要文字、页码、kicker
LINE   = RGBColor(0xDE, 0xE2, 0xE7)   # 浅灰：表头底
PAPER  = RGBColor(0xF5, 0xF7, 0xF9)   # 极浅灰：分组块底
ACCENT = RGBColor(0x2E, 0x6F, 0xB8)   # 唯一的强调色
WARN   = RGBColor(0xC1, 0x6B, 0x2E)   # 只留给「一句话」那一行
WHITE  = RGBColor(0xFF, 0xFF, 0xFF)

# 旧常量名保留（各页函数仍在引用），值全部收敛到上面这套。
# GREEN / RED / BLUE / ORANGE 的语义从「四种情绪色」降为「强调 / 中性 / 强调 / 提醒」，
# 于是「本项目 vs 主流」这类对比不再靠红绿对立，而靠正文内容本身说话。
NAVY, BLUE, ORANGE = INK, ACCENT, WARN
GREEN, RED = ACCENT, MUTED
LIGHT, LIGHT2 = PAPER, PAPER
GREENBG, REDBG = PAPER, PAPER

W_IN, H_IN = 13.333, 7.5
M_IN = 0.72
CW_IN = W_IN - 2 * M_IN

NO_GRID = '{2D5ABB26-0587-4C30-8999-92F81FD0307C}'   # "No Style, No Grid"


# ---------------------------------------------------------------- 基础工具
def style(run, size, bold=False, color=TEXT, italic=False):
    f = run.font
    f.size = Pt(size)
    f.bold = bold
    f.italic = italic
    f.color.rgb = color
    f.name = FONT
    rPr = run._r.get_or_add_rPr()
    for tag in ('a:ea', 'a:cs'):
        el = rPr.find(qn(tag))
        if el is None:
            el = rPr.makeelement(qn(tag), {})
            rPr.append(el)
        el.set('typeface', FONT)
    return run


def textbox(slide, l, t, w, h, anchor=MSO_ANCHOR.TOP):
    tb = slide.shapes.add_textbox(Inches(l), Inches(t), Inches(w), Inches(h))
    tf = tb.text_frame
    tf.word_wrap = True
    tf.margin_left = tf.margin_right = tf.margin_top = tf.margin_bottom = 0
    tf.vertical_anchor = anchor
    return tf


def line(tf, segments, size=14, align=PP_ALIGN.LEFT, before=0, after=6, first=False):
    p = tf.paragraphs[0] if first else tf.add_paragraph()
    p.alignment = align
    p.space_before = Pt(before)
    p.space_after = Pt(after)
    for txt, ov in segments:
        r = p.add_run()
        r.text = txt
        style(r, ov.get('size', size), ov.get('bold', False),
              ov.get('color', TEXT), ov.get('italic', False))
    return p


def rect(slide, l, t, w, h, fill=None, line_color=None, rounded=False, radius=0.10):
    shp = slide.shapes.add_shape(
        MSO_SHAPE.ROUNDED_RECTANGLE if rounded else MSO_SHAPE.RECTANGLE,
        Inches(l), Inches(t), Inches(w), Inches(h))
    if rounded:
        try:
            shp.adjustments[0] = radius
        except Exception:
            pass
    if fill is None:
        shp.fill.background()
    else:
        shp.fill.solid()
        shp.fill.fore_color.rgb = fill
    if line_color is None:
        shp.line.fill.background()
    else:
        shp.line.color.rgb = line_color
        shp.line.width = Pt(1)
    try:
        shp.shadow.inherit = False
    except Exception:
        pass
    tf = shp.text_frame
    tf.word_wrap = True
    # 关键：PowerPoint auto shape 的文字默认「垂直居中」，会让卡片顶部空一大块。
    # 统一改回顶对齐；需要居中的调用方（如 oneliner）在自己那里显式覆盖。
    tf.vertical_anchor = MSO_ANCHOR.TOP
    tf.margin_left = Inches(0.18)
    tf.margin_right = Inches(0.18)
    tf.margin_top = Inches(0.10)
    tf.margin_bottom = Inches(0.10)
    return shp


def set_table_style(tbl):
    tblPr = tbl._tbl.tblPr
    el = tblPr.find(qn('a:tableStyleId'))
    if el is None:
        el = tblPr.makeelement(qn('a:tableStyleId'), {})
        tblPr.append(el)
    el.text = NO_GRID


def table(slide, l, t, w, col_w, data, font=12, row_h=0.45,
          head_fill=LINE, head_color=INK,
          col_colors=None, aligns=None):
    """data[0] 为表头。col_colors: {列索引: 该列正文颜色}

    简约化：表头从「深色实心 + 白色字」改成「浅灰底 + 墨色字」，正文行去掉斑马纹，
    整张表只有表头一个色块 —— 表格靠对齐和留白读，不靠色带。
    """
    rows, cols = len(data), len(data[0])
    gf = slide.shapes.add_table(rows, cols, Inches(l), Inches(t),
                                Inches(w), Inches(row_h * rows))
    tbl = gf.table
    tbl.first_row = False
    tbl.horz_banding = False
    set_table_style(tbl)
    for i, cw in enumerate(col_w):
        tbl.columns[i].width = Inches(cw)
    for r, rowdata in enumerate(data):
        tbl.rows[r].height = Inches(row_h)
        for c, val in enumerate(rowdata):
            cell = tbl.cell(r, c)
            cell.margin_left = Inches(0.11)
            cell.margin_right = Inches(0.09)
            cell.margin_top = Inches(0.03)
            cell.margin_bottom = Inches(0.03)
            cell.vertical_anchor = MSO_ANCHOR.MIDDLE
            cell.fill.solid()
            if r == 0:
                cell.fill.fore_color.rgb = head_fill
            else:
                cell.fill.fore_color.rgb = WHITE
            tf = cell.text_frame
            tf.word_wrap = True
            p = tf.paragraphs[0]
            p.alignment = PP_ALIGN.LEFT if not aligns else aligns[c]
            p.space_after = Pt(0)
            run = p.add_run()
            run.text = str(val)
            if r == 0:
                style(run, font, True, head_color)
            else:
                col = TEXT if not col_colors else col_colors.get(c, TEXT)
                style(run, font, False, col)
    return tbl


def header(slide, title, kicker=None, page=None, big=False):
    y = 0.50
    if kicker:
        # kicker 降为灰色细体：它是导航标签，不该和标题抢注意力
        tf = textbox(slide, M_IN, y, CW_IN, 0.28)
        line(tf, [(kicker, {'size': 11, 'color': MUTED})], first=True, after=0)
        y += 0.32
    tf = textbox(slide, M_IN, y, CW_IN, 0.60)
    line(tf, [(title, {'size': 26 if not big else 29, 'bold': True, 'color': INK})],
         first=True, after=0)
    y += 0.58
    rect(slide, M_IN, y, 0.85, 0.05, fill=ACCENT)
    if page is not None:
        # 宽度给足：早前只有 1.2"，「备用」两个字被挤成竖排
        tf = textbox(slide, W_IN - M_IN - 2.8, H_IN - 0.48, 2.8, 0.28,
                     anchor=MSO_ANCHOR.MIDDLE)
        line(tf, [('Dayer 开题报告　', {'size': 9, 'color': MUTED}),
                  (str(page), {'size': 10, 'bold': True, 'color': MUTED})],
             align=PP_ALIGN.RIGHT, first=True, after=0)
    return y + 0.32


def oneliner(slide, y, text, label='一句话', color=ORANGE, fill=None):
    """本页最该被记住的一句。简约化：去掉整条色块，只留一根短横线做标记。"""
    rect(slide, M_IN, y, 0.9, 0.05, fill=color)
    tf = textbox(slide, M_IN, y + 0.22, CW_IN, 0.52)
    line(tf, [(label + '　', {'size': 11.5, 'bold': True, 'color': color}),
              (text, {'size': 15, 'bold': True, 'color': INK})], first=True, after=0)
    return y + 0.74


def card(slide, l, t, w, h, title, body, accent=ACCENT, bg=LIGHT2, tsize=14, bsize=12,
         num=None):
    """简约化：去掉左侧彩色条，标题一律墨色，只有序号带强调色。"""
    shp = rect(slide, l, t, w, h, fill=bg, rounded=True, radius=0.04)
    shp.text_frame.vertical_anchor = MSO_ANCHOR.TOP
    if num:
        # 序号写成标题行内的一个 run —— 早前用独立文本框叠在左上角，会压住标题文字
        line(shp.text_frame,
             [(num + '　', {'size': tsize + 2, 'bold': True, 'color': accent}),
              (title, {'size': tsize, 'bold': True, 'color': INK})],
             first=True, after=5)
    else:
        line(shp.text_frame, [(title, {'size': tsize, 'bold': True, 'color': INK})],
             first=True, after=5)
    if body:
        line(shp.text_frame, [(body, {'size': bsize, 'color': TEXT})], after=0)


# ---------------------------------------------------------------- 各页
def s01_cover(prs):
    s = prs.slides.add_slide(prs.slide_layouts[6])
    tf = textbox(s, 1.15, 1.05, CW_IN - 0.5, 0.35)
    line(tf, [('毕业设计（论文）开题报告', {'size': 14, 'bold': True, 'color': BLUE})],
         first=True, after=0)

    tf = textbox(s, 1.15, 1.62, CW_IN - 0.5, 1.5)
    line(tf, [('Dayer', {'size': 54, 'bold': True, 'color': NAVY})], first=True, after=2)
    line(tf, [('基于参考类预测的个人任务估时纠偏系统', {'size': 25, 'bold': True, 'color': TEXT})],
         after=2)
    line(tf, [('面向 HarmonyOS NEXT 的端侧实现', {'size': 16, 'color': MUTED})], after=0)

    shp = rect(s, 1.15, 3.62, CW_IN - 0.9, 1.05, fill=NAVY, rounded=True, radius=0.10)
    tf = shp.text_frame
    tf.vertical_anchor = MSO_ANCHOR.MIDDLE
    line(tf, [('别人在「展示」你的预估偏差，', {'size': 20, 'bold': True, 'color': WHITE})],
         first=True, after=2)
    line(tf, [('我们让系统在偏差发生前「介入」。',
               {'size': 20, 'bold': True, 'color': RGBColor(0xFF, 0xC1, 0x7A)})], after=0)

    tf = textbox(s, 1.15, 5.35, CW_IN - 0.9, 1.3)
    line(tf, [('汇报人：', {'size': 13, 'color': MUTED}),
              ('【姓名】', {'size': 13, 'bold': True, 'color': TEXT}),
              ('　　组员：', {'size': 13, 'color': MUTED}),
              ('【姓名】', {'size': 13, 'bold': True, 'color': TEXT})], first=True, after=4)
    line(tf, [('指导教师：', {'size': 13, 'color': MUTED}),
              ('【姓名】', {'size': 13, 'bold': True, 'color': TEXT}),
              ('　　汇报日期：', {'size': 13, 'color': MUTED}),
              ('【2026 年　月　日】', {'size': 13, 'bold': True, 'color': TEXT})], after=0)
    return s


def s02_theory(prs):
    s = prs.slides.add_slide(prs.slide_layouts[6])
    y = header(s, '选题的理论意义', kicker='一、项目背调', page=2)
    tf = textbox(s, M_IN, y, CW_IN, 0.34)
    line(tf, [('本课题要填的缺口，是文献自己指出来的。',
               {'size': 15, 'bold': True, 'color': ORANGE})], first=True, after=0)
    y += 0.46

    items = [
        ('①', '参考类预测（RCF）在「大型项目」层已被实证',
         'EJOR 2021：访谈 76 位项目经理、实证 52 个真实项目，证明其对成本与工期的预测有效。\n'
         '但在「个人日常任务」层面，此前完全未被实证检验。', BLUE),
        ('②', '「预测性可视化」在受控实验中被证明有效',
         'CHI 2022：145 人实验，把时长分布可视化后估计值平均上修 20%，乐观偏差显著下降。\n'
         '而更早的「拆解任务 / 列举意外 / 设想悲观情境」等做法基本无效。', BLUE),
        ('③', '有效策略已被系统性归纳',
         'UCL 博士论文综合 28 项实验研究，归纳出对任务管理工具有效的策略：\n'
         '及时细粒度的实际耗时反馈、基于同类历史任务的分布数据。', BLUE),
        ('④', '行业侧确认这是普遍缺口',
         'ACM 2024 扫描 47 款时间管理应用，指出「去除估时偏差（debiasing）」是普遍空白。', BLUE),
    ]
    ch, gap = 0.90, 0.12
    for num, title, body, col in items:
        card(s, M_IN, y, CW_IN, ch, title, body, accent=col, bg=LIGHT2,
             tsize=13.5, bsize=11.5, num=num)
        y += ch + gap

    tf = textbox(s, M_IN, y + 0.02, CW_IN, 0.5)
    line(tf, [('→　', {'size': 14, 'bold': True, 'color': ORANGE}),
              ('已被验证有效的方法（分布预测 + 及时反馈），至今没有被系统地落到'
               '「个人日常任务 + 便携设备端」这个场景。',
               {'size': 13.5, 'bold': True, 'color': NAVY})], first=True, after=0)
    return s


def s03_practice(prs):
    s = prs.slides.add_slide(prs.slide_layouts[6])
    y = header(s, '选题的实际意义', kicker='一、项目背调', page=3)
    tf = textbox(s, M_IN, y, CW_IN, 0.34)
    line(tf, [('这个问题被切成了两半，而两半从来没接上。',
               {'size': 15, 'bold': True, 'color': ORANGE})], first=True, after=0)
    y += 0.50

    data = [
        ['谁', '做了什么', '缺了什么'],
        ['Todoist / OmniFocus / Motion', '让用户填「预计耗时」', '多数不采集「实际耗时」'],
        ['RescueTime / Timing / Rize', '采集「实际耗时」', '不理解「预估」这个概念'],
    ]
    table(s, M_IN, y, CW_IN, [4.0, 3.9, 3.95], data, font=13, row_h=0.62,
          col_colors={2: RED})
    y += 0.62 * 3 + 0.30

    shp = rect(s, M_IN, y, CW_IN, 0.72, fill=REDBG, rounded=True, radius=0.10)
    tf = shp.text_frame
    tf.vertical_anchor = MSO_ANCHOR.MIDDLE
    line(tf, [('后果　', {'size': 12, 'bold': True, 'color': RED}),
              ('用户用了三年，估时能力不会变好 —— 记录本身不产生校准。',
               {'size': 15, 'bold': True, 'color': NAVY})], first=True, after=0)
    y += 0.72 + 0.30

    tf = textbox(s, M_IN, y, CW_IN, 0.9)
    line(tf, [('本土语境　', {'size': 12, 'bold': True, 'color': BLUE}),
              ('鸿蒙生态已上架的时间管理应用（时刻助手、时间盒子、7TIMERS、必行录）',
               {'size': 13, 'color': TEXT})], first=True, after=3)
    line(tf, [('全部偏「记录 + 提醒 + 可视化」，', {'size': 13, 'color': TEXT}),
              ('无一做「事前预估 → 事后校准」。',
               {'size': 13, 'bold': True, 'color': ORANGE})], after=0)
    return s


def s04_trend(prs):
    s = prs.slides.add_slide(prs.slide_layouts[6])
    y = header(s, '国内外研究动向', kicker='一、项目背调', page=4)
    tf = textbox(s, M_IN, y, CW_IN, 0.34)
    line(tf, [('方法已经清楚，场景还空着。',
               {'size': 15, 'bold': True, 'color': ORANGE})], first=True, after=0)
    y += 0.50

    cw = (CW_IN - 0.5) / 3
    cols = [
        ('学术', BLUE,
         '正从「展示」转向「预测 + 干预」',
         ['CHI 2022　预测性可视化（有效）',
          'CHIWORK 2025　真实场景并排展示（效果不显著）',
          '2026　轻量 AI 纠偏：预印本，仅有设计框架、未做出系统']),
        ('国外产品', BLUE,
         '小赛道被占住，大厂未落地',
         ['TimeBoxer / Beyond Time / FocusBox / AtlasNudge（2025–2026 独立小产品）',
          '微软有相关专利 US20190347621A1，但产品端未落地',
          '大厂均无长期准确率画像']),
        ('国内 / 鸿蒙', ORANGE,
         '空白',
         ['已上架的时间管理应用全部偏「记录 + 提醒 + 可视化」',
          '无一做「事前预估 → 事后校准」',
          '这是本项目切入的生态空位']),
    ]
    for i, (name, col, sub, bullets) in enumerate(cols):
        l = M_IN + i * (cw + 0.25)
        shp = rect(s, l, y, cw, 2.95, fill=LIGHT2, rounded=True, radius=0.06)
        tf = shp.text_frame
        line(tf, [(name, {'size': 15, 'bold': True, 'color': col})], first=True, after=3)
        line(tf, [(sub, {'size': 12, 'bold': True, 'color': NAVY})], after=9)
        for b in bullets:
            line(tf, [('· ', {'size': 11.5, 'bold': True, 'color': col}),
                      (b, {'size': 11.5, 'color': TEXT})], after=6)

    y += 2.95 + 0.45
    oneliner(s, y, '这个赛道的方法已经清楚，场景还空着 —— 本项目去占的就是这个空位。')
    return s


def s05_tech(prs):
    s = prs.slides.add_slide(prs.slide_layouts[6])
    y = header(s, '技术可行性', kicker='二、项目可行性', page=5)
    tf = textbox(s, M_IN, y, CW_IN, 0.34)
    line(tf, [('三层技术栈全部走官方链路，不依赖自建基础设施。',
               {'size': 15, 'bold': True, 'color': ORANGE})], first=True, after=0)
    y += 0.50

    data = [
        ['层', '选型', '理由'],
        ['界面', 'HarmonyOS NEXT Stage 模型 + ArkTS / ArkUI 原生', '非 Web 套壳，性能与生态一致'],
        ['数据', '本地关系型数据库', '用户数据不出设备'],
        ['推理', '端侧轻量推理（HSP 共享模块 + NAPI 桥接 C/C++）',
         '无网可用、无延迟、无隐私外泄'],
    ]
    table(s, M_IN, y, CW_IN, [1.3, 6.0, 4.55], data, font=12.5, row_h=0.62)
    y += 0.62 * 4 + 0.32

    shp = rect(s, M_IN, y, CW_IN, 1.30, fill=LIGHT, rounded=True, radius=0.07)
    tf = shp.text_frame
    tf.vertical_anchor = MSO_ANCHOR.MIDDLE
    line(tf, [('算法路线　', {'size': 13, 'bold': True, 'color': ORANGE}),
              ('刻意选简单 —— 统计基线 + 轻量模型分层，冷启动退化为保守系数。',
               {'size': 15, 'bold': True, 'color': NAVY})], first=True, after=7)
    line(tf, [('依据：同类 2026 研究同样选择「刻意简单的方法」，'
               '因为数据稀疏时也要能快速自适应；本项目不追求大模型。',
               {'size': 12, 'color': TEXT})], after=0)
    return s


def s06_feasible(prs):
    s = prs.slides.add_slide(prs.slide_layouts[6])
    y = header(s, '可行性保障', kicker='二、项目可行性', page=6)
    tf = textbox(s, M_IN, y, CW_IN, 0.34)
    line(tf, [('三个已知约束都已有预案，不需要在实现阶段才发现。',
               {'size': 15, 'bold': True, 'color': ORANGE})], first=True, after=0)
    y += 0.50

    cw = (CW_IN - 0.40) / 2
    # 左：资源可行性
    shp = rect(s, M_IN, y, cw, 3.05, fill=LIGHT2, rounded=True, radius=0.05)
    tf = shp.text_frame
    line(tf, [('资源可行性', {'size': 16, 'bold': True, 'color': GREEN})], first=True, after=10)
    for t, b in [
        ('平台', 'HarmonyOS NEXT 官方开发工具与模拟器，无需自建基础设施。'),
        ('数据', '预计耗时 / 实际耗时 / 类别全部由用户在应用内产生，\n'
                 '无需外部数据源或联网授权 —— 纯本地架构的优势。'),
        ('团队', '2 人 8 周，「应用层 / 数据与算法层」并行推进；\n'
                 '每周均有可运行交付物，第 4 周即产出最小闭环。'),
    ]:
        line(tf, [(t + '　', {'size': 12.5, 'bold': True, 'color': GREEN}),
                  (b, {'size': 11.5, 'color': TEXT})], after=9)

    # 右：风险与预案
    l2 = M_IN + cw + 0.40
    shp = rect(s, l2, y, cw, 3.05, fill=REDBG, rounded=True, radius=0.05)
    tf = shp.text_frame
    line(tf, [('风险与预案', {'size': 16, 'bold': True, 'color': ORANGE})], first=True, after=10)
    for t, b in [
        ('应用切后台会被系统冻结', '申请后台持续任务；\n推理做分片 + 中断保存，切回前台可恢复。'),
        ('系统通知权限限制严格', '纠偏提示改为应用内主动干预 —— 反而更贴合「纠偏」场景：\n'
                                 '用户正在做这件事时才需要被提醒。'),
        ('端侧算力 / 内存有限', '不追求大模型；分层降级，稀疏场景走保守基线。'),
        ('参考类样本可能过小', '这是方法本身的固有代价（见创新点二），\n'
                               '本项目要解决的正是稀疏数据下的退化策略。'),
    ]:
        line(tf, [(t + '　', {'size': 12.5, 'bold': True, 'color': RED}),
                  (b, {'size': 11.5, 'color': TEXT})], after=9)
    return s


def s07_innov1(prs):
    s = prs.slides.add_slide(prs.slide_layouts[6])
    y = header(s, '创新点一 · 机制：从「被动展示」到「主动纠偏」',
               kicker='三、特色与创新　1 / 3', page=7)
    data = [
        ['', '主流做法', '本项目'],
        ['展示什么', '待办列表 + 计划时间', '预估 vs 实际偏差'],
        ['何时干预', '提醒「该做了」', '在你估错之前提示'],
        ['最终目标', '别忘事', '提升你的估时能力'],
    ]
    table(s, M_IN, y, CW_IN, [2.9, 4.5, 4.49], data, font=14, row_h=0.68,
          col_colors={2: GREEN})
    y += 0.68 * 4 + 0.28

    shp = rect(s, M_IN, y, CW_IN, 1.20, fill=LIGHT2, rounded=True, radius=0.07)
    tf = shp.text_frame
    tf.vertical_anchor = MSO_ANCHOR.MIDDLE
    line(tf, [('理论依据　', {'size': 12.5, 'bold': True, 'color': BLUE}),
              ('CHIWORK 2025 显示，单纯把「计划 vs 实际」并排展示，效果并不显著；',
               {'size': 13, 'color': TEXT})], first=True, after=4)
    line(tf, [('而 CHI 2022 显示，给出基于分布的预测确实能降低乐观偏差。',
               {'size': 13, 'color': TEXT})], after=5)
    line(tf, [('→　差别在「有没有给出预测」，不在「有没有展示对比」。',
               {'size': 13.5, 'bold': True, 'color': ORANGE})], after=0)
    y += 1.20 + 0.24

    oneliner(s, y, '系统不告诉你「你错了」，而是在你还来得及改的时候，告诉你「你大概会错多少」。')
    return s


def s08_innov2(prs):
    s = prs.slides.add_slide(prs.slide_layouts[6])
    y = header(s, '创新点二 · 方法：用「参考类预测」替代固定倍率',
               kicker='三、特色与创新　2 / 3', page=8)

    cw = (CW_IN - 0.36) / 2
    shp = rect(s, M_IN, y, cw, 1.48, fill=REDBG, rounded=True, radius=0.07)
    tf = shp.text_frame
    line(tf, [('✕　劣质做法', {'size': 14, 'bold': True, 'color': RED})], first=True, after=5)
    line(tf, [('硬编码 ×1.4 / ×1.2 的缓冲系数。',
               {'size': 12.5, 'bold': True, 'color': TEXT})], after=4)
    line(tf, [('不使用用户任何个人数据 —— 这是假闭环。',
               {'size': 12, 'color': TEXT})], after=0)

    l2 = M_IN + cw + 0.36
    shp = rect(s, l2, y, cw, 1.48, fill=GREENBG, rounded=True, radius=0.07)
    tf = shp.text_frame
    line(tf, [('✓　本项目的做法', {'size': 14, 'bold': True, 'color': GREEN})], first=True, after=5)
    line(tf, [('从用户自己的历史完成记录中，按类别 / 相似任务取分布'
               '（中位数 + 坏尾巴）→ 个性化系数。',
               {'size': 12.5, 'bold': True, 'color': TEXT})], after=4)
    line(tf, [('偏差超阈值时主动提示，用户可采纳或驳回；驳回本身也被记录，用于后续校准。',
               {'size': 12, 'color': TEXT})], after=0)
    y += 1.48 + 0.26

    tf = textbox(s, M_IN, y, CW_IN, 0.34)
    line(tf, [('理论支撑　', {'size': 12, 'bold': True, 'color': BLUE}),
              ('EJOR 2021（RCF 在项目层经 52 个真实项目实证）　·　'
               'UCL 综述归纳的有效策略：依赖同类历史任务的分布数据',
               {'size': 12, 'color': TEXT})], first=True, after=0)
    y += 0.42

    shp = rect(s, M_IN, y, CW_IN, 0.90, fill=LIGHT, rounded=True, radius=0.08)
    tf = shp.text_frame
    tf.vertical_anchor = MSO_ANCHOR.MIDDLE
    line(tf, [('难点与贡献　', {'size': 12.5, 'bold': True, 'color': ORANGE}),
              ('RCF 的固有代价：纳入属性越多预测越准，参考类样本越小越不可靠。'
               '数据稀疏时如何优雅退化，正是本项目要解决的问题。',
               {'size': 12.5, 'color': TEXT})], first=True, after=0)
    y += 0.90 + 0.16

    tf = textbox(s, M_IN, y, CW_IN, 0.30)
    line(tf, [('差异化　', {'size': 12, 'bold': True, 'color': BLUE}),
              ('2026 那篇预印本思路相近，但只给出设计框架、未做出系统；本项目交付可运行系统。',
               {'size': 12, 'color': TEXT})], first=True, after=0)
    y += 0.40

    oneliner(s, y, '不用「猜你大概会超时 40%」，而用「你自己过去做这类事，超时的分布长什么样」。')
    return s


def s09_innov3(prs):
    s = prs.slides.add_slide(prs.slide_layouts[6])
    y = header(s, '创新点三 · 形态：端侧推理的鸿蒙原生实现',
               kicker='三、特色与创新　3 / 3', page=9)

    shp = rect(s, M_IN, y, CW_IN, 1.20, fill=GREENBG, rounded=True, radius=0.07)
    tf = shp.text_frame
    line(tf, [('A　端侧推理', {'size': 15, 'bold': True, 'color': GREEN})], first=True, after=5)
    line(tf, [('全本地推理：无需联网、无隐私外泄、无延迟。',
               {'size': 13, 'bold': True, 'color': TEXT})], after=4)
    line(tf, [('叠加鸿蒙生态空白 —— 已上架应用无一做「事前预估 → 事后校准」。',
               {'size': 12.5, 'color': TEXT})], after=0)
    y += 1.20 + 0.24

    shp = rect(s, M_IN, y, CW_IN, 2.05, fill=LIGHT2, rounded=True, radius=0.05)
    shp.text_frame.margin_left = Inches(0.30)
    tf = shp.text_frame
    line(tf, [('B　反「凑数字」设计', {'size': 15, 'bold': True, 'color': ORANGE})],
         first=True, after=6)
    line(tf, [('有研究发现：把计时数据可视化后，用户会去「凑数字」，而不是校准自己的预估。',
               {'size': 12.5, 'color': TEXT})], after=3)
    line(tf, [('国内同样有实证：排行榜导致「为了排行什么都记」、自习室引发攀比焦虑。',
               {'size': 12.5, 'color': TEXT})], after=6)
    line(tf, [('因此本项目刻意不做：', {'size': 12.5, 'bold': True, 'color': TEXT}),
              ('排行榜　/　连续打卡天数　/　社交比拼',
               {'size': 12.5, 'bold': True, 'color': RED})], after=3)
    line(tf, [('这些机制会让用户「为数据而记录」，恰好摧毁「提升估时能力」这个目标。',
               {'size': 12.5, 'color': TEXT})], after=0)
    y += 2.05 + 0.24

    oneliner(s, y, '一个不激励你「刷数据」、只帮你更准地估时间的应用。')
    return s


def s10_division(prs):
    s = prs.slides.add_slide(prs.slide_layouts[6])
    y = header(s, '具体分工与进度安排', kicker='四、分工', page=10)
    tf = textbox(s, M_IN, y, CW_IN, 0.32)
    line(tf, [('两人 × 8 周。「应用层 / 数据与算法层」切分，接口第 1 周冻结后可完全并行。',
               {'size': 12.5, 'bold': True, 'color': ORANGE})], first=True, after=0)
    y += 0.42

    data = [
        ['周', '成员 A（应用层 / 交互）', '成员 B（数据与算法层）', '周末交付物'],
        ['1', '需求细化、界面原型、交互流程', '技术选型验证、数据模型设计', '原型图 + 技术选型结论'],
        ['2', '首页任务列表、任务录入页', '本地数据库建表、DAO、增删改查', '可录入并显示任务'],
        ['3', '状态流转、编辑页、详情页', '实际耗时采集、偏差值计算', '任务全生命周期跑通'],
        ['4', '偏差原因录入、复盘界面', '估时准确率 / 分类耗时统计', '最小闭环（预估→执行→复盘）'],
        ['5', '纠偏提示交互（采纳 / 驳回）', '端侧推理模块搭建、个性化系数算法', '纠偏提示可用'],
        ['6', '首页时间轴、数据看板', '算法接入调参、稀疏数据退化策略', '主要功能齐备'],
        ['7', '联调、异常处理、体验打磨', '性能优化、后台任务与分片恢复', '稳定可演示'],
        ['8', '演示脚本、答辩材料、文档', '数据导出、最终测试', '可运行系统 + 报告'],
    ]
    table(s, M_IN, y, CW_IN, [0.7, 3.35, 3.98, 4.66], data, font=11, row_h=0.50)

    tf = textbox(s, M_IN, 6.72, CW_IN, 0.32)
    line(tf, [('贯穿机制　', {'size': 11, 'bold': True, 'color': BLUE}),
              ('每周一次例会 + 代码互审；A / B 角色可按实际技术栈对调，但第 1 周定死后中途不换。',
               {'size': 11, 'color': MUTED})], first=True, after=0)
    return s


def s11_closing(prs):
    s = prs.slides.add_slide(prs.slide_layouts[6])
    rect(s, 0, 0, W_IN, H_IN, fill=NAVY)
    tf = textbox(s, 1.0, 2.10, W_IN - 2.0, 0.5)
    line(tf, [('别人在「展示」你的预估偏差，', {'size': 26, 'bold': True, 'color': WHITE})],
         align=PP_ALIGN.CENTER, first=True, after=6)
    line(tf, [('我们让系统在偏差发生前「介入」。',
               {'size': 26, 'bold': True, 'color': RGBColor(0xFF, 0xC1, 0x7A)})],
         align=PP_ALIGN.CENTER, after=0)
    rect(s, (W_IN - 1.4) / 2, 3.55, 1.4, 0.055, fill=ORANGE)
    tf = textbox(s, 1.0, 3.95, W_IN - 2.0, 0.5)
    line(tf, [('恳请各位老师批评指正', {'size': 20, 'bold': True, 'color': WHITE})],
         align=PP_ALIGN.CENTER, first=True, after=0)
    tf = textbox(s, 1.0, 6.35, W_IN - 2.0, 0.4)
    line(tf, [('Dayer　·　基于参考类预测的个人任务估时纠偏系统',
               {'size': 12, 'color': RGBColor(0x8C, 0xA4, 0xC4)})],
         align=PP_ALIGN.CENTER, first=True, after=0)
    return s


def s12_backup(prs):
    s = prs.slides.add_slide(prs.slide_layouts[6])
    y = header(s, '备用答疑', kicker='答辩备用页（不计入汇报时间）', page='备用')
    qa = [
        ('Q1', '这和市面上的估时应用有什么区别？',
         '区别不在功能多少，而在机制 —— 别人展示偏差，我们预测并干预偏差。'),
        ('Q2', '2026 年已经有论文做这个方向了，你的贡献是什么？',
         '那篇是预印本，只给出设计框架与评估方法，未做出系统；'
         '本项目交付可运行系统，并处理了它未涉及的稀疏数据退化问题。'),
        ('Q3', '两个人 8 周做得完吗？',
         '最小闭环第 4 周即可产出；端侧推理走轻量方案且有冷启动兜底；'
         '算法与界面并行开发，接口第 1 周冻结。'),
    ]
    for q, title, ans in qa:
        shp = rect(s, M_IN, y, CW_IN, 1.00, fill=LIGHT2, rounded=True, radius=0.06)
        shp.text_frame.margin_left = Inches(0.30)
        tf = shp.text_frame
        line(tf, [(q + '　', {'size': 14, 'bold': True, 'color': BLUE}),
                  (title, {'size': 14, 'bold': True, 'color': NAVY})], first=True, after=5)
        line(tf, [('→　', {'size': 12, 'bold': True, 'color': ORANGE}),
                  (ans, {'size': 12.5, 'color': TEXT})], after=0)
        y += 1.00 + 0.50
    return s


# ---------------------------------------------------------------- 主流程
def main():
    out = sys.argv[1] if len(sys.argv) > 1 else 'Dayer开题答辩.pptx'
    prs = Presentation()
    prs.slide_width = Inches(W_IN)
    prs.slide_height = Inches(H_IN)

    s01_cover(prs)
    s02_theory(prs)
    s03_practice(prs)
    s04_trend(prs)
    s05_tech(prs)
    s06_feasible(prs)
    s07_innov1(prs)
    s08_innov2(prs)
    s09_innov3(prs)
    s10_division(prs)
    s11_closing(prs)
    s12_backup(prs)

    prs.save(out)
    print('OK ->', out)
    print('slides:', len(prs.slides._sldIdLst))


if __name__ == '__main__':
    main()
