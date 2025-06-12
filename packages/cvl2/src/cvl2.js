{
class Src {
  str;
  idx;
  line_indent_level;
  lyn;
  col;
  fname="file";
  constructor(str) {this.str = str;this.idx = 0;this.calcIndent();this.lyn=1;this.col=1}
  peek() {
    return this.str[this.idx] ?? "";
  }
  take() {
    const res = this.peek();
    this.idx += res.length;
    if(res === "\n") {
      this.lyn += 1;
      this.col  = 1;
      this.calcIndent();
    }
    this.col += res.length;
    return res;
  }
  calcIndent() {
    let sub = this.str.substring(this.idx);
    let idnt = sub.match(/^ */)[0];
    this.line_indent_level = idnt.length;
  }
}

const src = new Src(`abc [
    def [jkl]
    if (
        amazing;
    ] else {
        wow!;
    }
    demoFn(1, 2,
    	3,
    	4, 5, 6,
    7, 8)
    commaExample(1, 2, 3, 4)
    colonExample(a: 1, b: c: 2, 3)
] ghi`);
function tkz(src) {
let current = [];
let errors = [];
const stack = [];
stack.push({idx: 0, char: "", indent: -1, val: current,prec:0});

while(src.peek()) {
const start = src.idx;
const start_lyn = src.lyn;
const start_col = src.col;
const char = src.take();

const ident = /^[a-zA-Z0-9]$/;
const ws = /^\s$/;
const lb = [..."([{"];
const rb = [...")]}"];
if(char.match(ident)) {
   while(src.peek().match(ident)) {
      src.take();
   }
   current.push({kind:"ident",pos:{idx:start,lyn:start_lyn,col:start_col},str:src.str.substring(start, src.idx)});
}else if(char.match(ws)) {
   while(src.peek().match(ws)) {
      src.take();
   }
   current.push({kind:"ws",pos:{idx:start,lyn:start_lyn,col:start_col},nl:src.str.substring(start, src.idx).includes("\n")});

}else if(lb.includes(char)) {
  let next = [];
  current.push({kind: "block",pos:{idx:start,lyn:start_lyn,col:start_col}, start:char,end:rb[lb.indexOf(char)], items: next});
  stack.push({idx: start,lyn:start_lyn,col:start_col, char, indent: src.line_indent_level, val: next, prec:0});
  current = next;
}else if(char === ":") {
  let next = [];
  current.push({kind: "block",pos:{idx:start,lyn:start_lyn,col:start_col}, start:char,end:"", items: next});
  stack.push({idx: start,lyn:start_lyn,col:start_col, char, indent: src.line_indent_level, val: next, prec:2, autoClose: true});
  current = next;
}else if(rb.includes(char)) {
  const b = lb[rb.indexOf(char)];
  const indent = +src.line_indent_level;
  while(stack.length > 1) {
		const last = stack.pop();
    if(last.char === b && last.indent === indent) {
      // perfect
      current = stack[stack.length - 1].val;
      break;
    }
    if(last.indent < indent) {
      errors.push(`${src.fname}:${start_lyn}:${start_col} error: extra close bracket`);
      stack.push(last);
      break;
    }else{
      if(!last.autoClose) errors.push([`${src.fname}:${last.lyn}:${last.col} error: open bracket missing close bracket`,`${src.fname}:${start_lyn}:${start_col} note: expected for '${last.char}' indent '${last.indent}', got '${char}' indent '${indent}'`]);
      current = stack[stack.length - 1].val;
    }
  }
}else if(char === "," || char === ";") {
  const op_prec = 1;
  // find spot with prec <= 1
  let atComma;
let  i = 0;
  while(stack.length > 0) {
i++;
if(i > 1000) throw new Error("oops");
    const last = stack[stack.length - 1];
    if(last.prec === op_prec) {
      atComma = last;
      break;
    }else if(last.prec < op_prec) {
    	atComma = {
        idx:start,
        lyn:start_lyn,
        col:start_col,
        char: char,
        val: [...last.val],
        indent: last.indent,
        autoClose: true,
        prec:op_prec,
      }
      stack.push(atComma);
      last.val.splice(0, last.val.length, {
			    kind: "binary",
          pos:{idx:start,lyn:start_lyn,col:start_col},
          prec: op_prec,
					items: atComma.val,
      });
      break;
    }else{
      if(!last.autoClose) errors.push([`${src.fname}:${start_lyn}:${start_col} auto-closing non autoclose-able item. ${src.frame}:${last.lyn}:${last.col} note: opened here`]);
      stack.pop();
    }
  }
  if(!atComma) throw new Error("unreachable");
  // if(atComma.char !== char) errors.push(`${src.fname}:${start_lyn}:${start_col} mixed`);
  current = stack[stack.length - 1].val;
  current.push({
    kind: "op",
    pos:{idx:start,lyn:start_lyn,col:start_col},
    op: char,
  });
  
}else{

errors.push(`${src.fname}:${start_lyn}:${start_col} error: bad char \"${JSON.stringify(char)}\"`);

}

}

return {result:stack[0].val,errors};
}

  
function renderEntityList(cfg, ents, level, toplevel) {
let res = "";
let di = false;
let dn = false;
let lastNewline = 0;
for(let i = 0; i < ents.length; i++) {
  const it = ents[i];
	if(it.kind === "ws" && it.nl) lastNewline = i;
}
for(let i = 0; i < ents.length; i++) {
  const it = ents[i];
  if(it.kind === "ws") {
    if(it.nl && !dn){
      di = !toplevel && i < lastNewline;
      dn = true;
      res += "\n" + cfg.indent.repeat(level+di);
    }else{
			res += " ";
    }
  }else{
    dn = false;
  	res += renderEntity(cfg, it, level + di, toplevel);
  }
}
return res;
}
function renderEntity(cfg, ent, level, toplevel) {
if(cfg.style === "s") {
  if(ent.kind === "block") {
  return `(${JSON.stringify(ent.start + ent.end)} ` + renderEntityList(cfg, ent.items, level, false) + ")";
  }else if(ent.kind === "binary") {
  return "(binary " + renderEntityList(cfg, ent.items, level, toplevel) + ")";
  }else if(ent.kind === "ws") {
  throw new Error("unreachable");
  }else if(ent.kind === "ident") {
  return "$" + ent.str;
  }else if(ent.kind === "op") {
  return JSON.stringify(ent.op);
  }else return "(TODO $"+ent.kind+")";
}else{
  if(ent.kind === "block") {
  return ent.start + renderEntityList(cfg, ent.items, level, false) + ent.end;
  }else if(ent.kind === "binary") {
  return renderEntityList(cfg, ent.items, level, toplevel);
  }else if(ent.kind === "ws") {
  throw new Error("unreachable");
  }else if(ent.kind === "ident") {
  return ent.str;
  }else if(ent.kind === "op") {
  return ent.op;
  }else return "%TODO<"+ent.kind+">%";
}
}


function renderTkz(tkz, src) {

return "// formatted\n" + renderEntityList({indent: "  "}, tkz.result, 0, true)+ "\n\n// s-expr:\n" + renderEntityList({indent: "  ",style:"s"}, tkz.result, 0, true) + "\n\n// errors:\n" + JSON.stringify(tkz.errors, null, 2);
}

console.log(renderTkz(tkz(src), src))
}