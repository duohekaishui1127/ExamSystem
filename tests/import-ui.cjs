// Run with Node.js; tests the actual page functions with a minimal DOM fixture.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const html = fs.readFileSync(path.join(__dirname, '../web/admin.html'), 'utf8');
const source = html.match(/<script>([\s\S]*?)<\/script>/)[1];
new vm.Script(source); // Parse the entire page script.
function functionSource(name) {
  const start = source.search(new RegExp('^(async )?function ' + name + '\\(', 'm'));
  assert(start >= 0, name);
  const tail = source.slice(start);
  const end = tail.indexOf('\nfunction ');
  const asyncEnd = tail.indexOf('\nasync function ');
  const bounds = [end, asyncEnd].filter(x => x >= 0);
  return tail.slice(0, Math.min(...bounds));
}
const list = { children: [], appendChild(node) { this.children.push(node); }, set innerHTML(v) { this.children = []; } };
const button = { disabled: false, textContent: '' };
const status = { classList: { remove() {} }, textContent: '' };
const context = {
  questionPage: 0, questionList: list, questionPager: { innerHTML: '' },
  questions: Array.from({ length: 1500 }, (_, i) => ({ id:i+1,type:'subjective',text:'Question '+(i+1),answerText:'Answer' })),
  document: { createElement: () => ({ innerHTML: '', className: '' }) },
  esc: String, optionsHtml: () => '', mediaHtml: () => '', markedQuestion: q => q.text,
  exam: { status: 'draft' }, importingQuestions: false, importQuestionBtn: button, importStatus: status,
  alert() {}, readImportBase64: async () => 'encoded', loadQuestions: async () => {},
  api: async () => ({ importedCount: 5, totalRows: 6, errors: ['Invalid row'] }),
};
vm.createContext(context);
for (const name of ['changeQuestionPage','renderQuestions','importQuestionFile']) vm.runInContext(functionSource(name),context);
(async () => {
  context.renderQuestions();
  assert.equal(list.children.length,50);
  assert(context.questionPager.innerHTML.includes('共 1500 题'));
  context.changeQuestionPage(1);
  assert(list.children[0].innerHTML.includes('第 51 题'));
  assert(list.children[0].innerHTML.includes('editQuestion(51)'));
  context.changeQuestionPage(1000);
  assert.equal(context.questionPage,29);
  assert.equal(list.children.length,50);
  context.questions=context.questions.slice(0,10);context.renderQuestions();
  assert.equal(context.questionPage,0);assert.equal(list.children.length,10);
  const input = () => ({ files:[{name:'questions.xlsx',size:100}],value:'file' });
  await context.importQuestionFile(input());
  assert(status.textContent.includes('成功导入 5 道题'));
  assert.equal(button.disabled,false);assert.equal(context.importingQuestions,false);
  context.api=async()=>{ throw Error('test failure') };
  await context.importQuestionFile(input());
  assert(status.textContent.includes('test failure'));
  assert.equal(button.disabled,false);assert.equal(context.importingQuestions,false);
  let release;
  context.api=()=>new Promise(resolve=>{release=resolve});
  const pending=context.importQuestionFile(input());
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(button.disabled,true);
  await context.importQuestionFile(input()); // Duplicate submission must return without issuing another request.
  release({importedCount:1,totalRows:1,errors:[]});await pending;
  assert.equal(context.importingQuestions,false);
  console.log('PASS: 50-row pagination, numbering, page bounds, import success/failure state, duplicate prevention');
})().catch(e=>{console.error(e);process.exitCode=1});
