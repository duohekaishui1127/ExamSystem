"""Build the dropdown-enabled XLSX and matching CSV using only Python's standard library."""
from pathlib import Path
from xml.etree import ElementTree as ET
from zipfile import ZipFile, ZIP_DEFLATED
import csv
import itertools

ROOT = Path(__file__).resolve().parents[1]
NS = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
REL = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
ET.register_namespace('', NS)
ET.register_namespace('r', REL)

def el(parent, tag, **attrs):
    return ET.SubElement(parent, '{'+NS+'}'+tag, {k: str(v) for k, v in attrs.items()})

def xml(node):
    return ET.tostring(node, encoding='utf-8', xml_declaration=True)

HEADERS = ['题型','题目正文','判断结果','错误部分','标准答案','作答方式','选项A','选项B','选项C','选项D','正确选项']
ROWS = [
    ['判断题','HTTP 默认使用 UDP 协议传输。','错误','UDP','','','','','','',''],
    ['判断题','TCP 是面向连接的传输层协议。','正确','','','','','','','',''],
    ['主观题','V4L2 的主要作用是什么？','','','Linux 系统通过 V4L2 访问视频设备','','','','','',''],
    ['选择题','以下哪个数字是偶数？','','','','单选','1','2','3','5','B'],
    ['选择题','以下哪些数字是偶数？','','','','多选','2','3','4','5','A,C'],
]

def sheet(rows, widths, editable=False):
    root = ET.Element('{'+NS+'}worksheet')
    view = el(el(root, 'sheetViews'), 'sheetView', workbookViewId=0)
    el(view, 'pane', ySplit=1, topLeftCell='A2', activePane='bottomLeft', state='frozen')
    el(root, 'sheetFormatPr', defaultRowHeight=24)
    cols = el(root, 'cols')
    for i, width in enumerate(widths, 1):
        el(cols, 'col', min=i, max=i, width=width, customWidth=1, style=1 if editable else 0)
    data = el(root, 'sheetData')
    for r, values in enumerate(rows, 1):
        row = el(data, 'row', r=r, ht=36 if r==1 else 42, customHeight=1)
        for c, value in enumerate(values):
            if value == '' and r != 1:
                continue
            cell = el(row, 'c', r=f'{chr(65+c)}{r}', t='inlineStr', s=2 if r==1 else (1 if editable else 0))
            text = el(el(cell, 'is'), 't')
            text.set('{http://www.w3.org/XML/1998/namespace}space', 'preserve')
            text.text = str(value)
    if editable:
        # Protect the headers; input columns remain unlocked without pre-creating blank rows.
        el(root, 'sheetProtection', sheet=1, objects=1, scenarios=1, selectLockedCells=1, selectUnlockedCells=0, formatColumns=0)
        validations = el(root, 'dataValidations', count=4)
        for column, formula, prompt in [
            ('A','QuestionTypes','请选择判断题、主观题或选择题'),
            ('C','Judgements','判断题请选择正确或错误，其他题型留空'),
            ('F','ChoiceModes','选择题请选择单选或多选，其他题型留空'),
            ('K','IF($F2="单选",SingleAnswers,MultiAnswers)','先选择作答方式，再从下拉中选择正确选项组合'),
        ]:
            rule = el(validations, 'dataValidation', type='list', errorStyle='stop', allowBlank=1,
                      showDropDown=0, showInputMessage=1, showErrorMessage=1,
                      sqref=f'{column}2:{column}1048576', promptTitle='从下拉列表选择', prompt=prompt,
                      errorTitle='无效选项', error='请使用下拉列表中的值，不要填写其他内容。')
            el(rule, 'formula1').text = formula
    return root

def build():
    lists = [
        ['判断题','主观题','选择题'], ['正确','错误'], ['单选','多选'], list('ABCD'),
        [','.join(keys) for n in (2,3,4) for keys in itertools.combinations('ABCD',n)],
    ]
    list_rows = [[values[i] if i<len(values) else '' for values in lists] for i in range(11)]
    notes = [
        ['填写说明'],
        ['请在 Questions 工作表第 2 行起填写自己的题目；示例参考工作表仅供查看，无需删除，不参与导入。'],
        ['题型、判断结果、作答方式、正确选项使用下拉选择；无效键入会被 Excel 阻止。'],
        ['判断题：填写题目正文和判断结果；选择错误时，错误部分须在正文中恰好出现一次。'],
        ['主观题：填写题目正文及标准答案；其他专用列留空。'],
        ['选择题：作答方式选单选/多选，填写四个选项，在正确选项列选择答案组合。'],
        ['单选答案只能是 A/B/C/D；多选答案至少两个，全部选对才算正确。'],
        ['题目正文、选项和主观题标准答案自由填写；图片和附件请导入后在后台编辑题目添加。'],
        ['标题行已保护，数据输入列可编辑；不需要新增空白行，直接在下面继续填写。'],
        ['Excel 可键入合法值；部分软件或粘贴操作可能绕过下拉校验，导入时服务端会再次检查。'],
        ['CSV 不支持下拉或单元格校验，但使用同样的列和导入校验；推荐使用 XLSX 模板。'],
    ]
    workbook = ET.Element('{'+NS+'}workbook')
    sheets = el(workbook, 'sheets')
    for i, name in enumerate(['Questions','说明','选项列表','示例参考'], 1):
        node = el(sheets, 'sheet', name=name, sheetId=i)
        node.set('{'+REL+'}id', f'rId{i}')
        if i==3: node.set('state','veryHidden')
    names = el(workbook, 'definedNames')
    for name, col, length in [('QuestionTypes','A',3),('Judgements','B',2),('ChoiceModes','C',2),('SingleAnswers','D',4),('MultiAnswers','E',11)]:
        el(names,'definedName',name=name).text=f"'选项列表'!${col}$1:${col}${length}"
    styles = f'''<styleSheet xmlns="{NS}"><fonts count="2"><font><sz val="11"/><name val="Microsoft YaHei"/></font><font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Microsoft YaHei"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF5368DF"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="3"><xf numFmtId="49" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf><xf numFmtId="49" fontId="0" fillId="0" borderId="0" xfId="0" applyProtection="1" applyAlignment="1"><alignment vertical="center" wrapText="1"/><protection locked="0"/></xf><xf numFmtId="49" fontId="1" fillId="2" borderId="0" xfId="0" applyAlignment="1" applyProtection="1"><alignment horizontal="center" vertical="center" wrapText="1"/><protection locked="1"/></xf></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>'''
    rels_ns='http://schemas.openxmlformats.org/package/2006/relationships'
    workbook_rels=f'<Relationships xmlns="{rels_ns}">'+''.join(f'<Relationship Id="rId{i}" Type="{REL}/worksheet" Target="worksheets/sheet{i}.xml"/>' for i in range(1,5))+f'<Relationship Id="rId5" Type="{REL}/styles" Target="styles.xml"/></Relationships>'
    content_types='<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'+''.join(f'<Override PartName="/xl/worksheets/sheet{i}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' for i in range(1,5))+'</Types>'
    with ZipFile(ROOT/'QUESTION_IMPORT_TEMPLATE.xlsx','w',ZIP_DEFLATED) as z:
        z.writestr('[Content_Types].xml',content_types)
        z.writestr('_rels/.rels',f'<Relationships xmlns="{rels_ns}"><Relationship Id="rId1" Type="{REL}/officeDocument" Target="xl/workbook.xml"/></Relationships>')
        z.writestr('xl/workbook.xml',xml(workbook))
        z.writestr('xl/_rels/workbook.xml.rels',workbook_rels)
        z.writestr('xl/styles.xml',styles)
        z.writestr('xl/worksheets/sheet1.xml',xml(sheet([HEADERS],[16,48,14,24,40,14,26,26,26,26,20],True)))
        z.writestr('xl/worksheets/sheet2.xml',xml(sheet(notes,[115])))
        z.writestr('xl/worksheets/sheet3.xml',xml(sheet(list_rows,[16]*5)))
        z.writestr('xl/worksheets/sheet4.xml',xml(sheet([HEADERS]+ROWS,[16,48,14,24,40,14,26,26,26,26,20])))
    with (ROOT/'QUESTION_IMPORT_TEMPLATE.csv').open('w',encoding='utf-8-sig',newline='') as f:
        csv.writer(f, lineterminator="\n").writerows([HEADERS])

if __name__=='__main__':
    build()
