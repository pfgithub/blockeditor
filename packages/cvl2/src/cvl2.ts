function unreachable(): never {
    throw new Error("unreachable");
}

type Config = {
    style: "open" | "close" | "join",
    prec: number,
    close?: string,
};
const config: Record<string, Config> = {
    "(": {style: "open", prec: 0, close: ")"},
    "{": {style: "open", prec: 0, close: "}"},
    "[": {style: "open", prec: 0, close: "]"},
    ")": {style: "close", prec: 0},
    "}": {style: "close", prec: 0},
    "]": {style: "close", prec: 0},
    "=>": {style: "join", prec: 1},
    ",": {style: "join", prec: 2},
    ";": {style: "join", prec: 2},
    ":": {style: "open", prec: 3},
    "=": {style: "join", prec: 4},

    // TODO: "=>"
    // TODO: "\()" as style open prec 0 autoclose display{open: "(", close: ")"}
};

const referenceTrace: TokenPosition[] = [];
function withReferenceTrace(pos: TokenPosition): {[Symbol.dispose]: () => void} {
    referenceTrace.push(pos);
    return {[Symbol.dispose]() {
        const popped = referenceTrace.pop();
        if(popped !== pos) unreachable();
    }};
}

class Source {
    public text: string;
    public currentIndex: number;
    public currentLine: number;
    public currentCol: number;
    public filename: string;
    public currentLineIndentLevel: number;

    constructor(filename: string, text: string) {
        this.text = text;
        this.currentIndex = 0;
        this.currentLine = 1;
        this.currentCol = 1;
        this.filename = filename;
        this.currentLineIndentLevel = this.calculateIndent();
    }

    peek(): string {
        return this.text[this.currentIndex] ?? "";
    }

    take(): string {
        const character = this.peek();
        this.currentIndex += character.length;

        if (character === "\n") {
            this.currentLine += 1;
            this.currentCol = 1;
            this.currentLineIndentLevel = this.calculateIndent();
        } else {
            this.currentCol += character.length;
        }
        return character;
    }

    private calculateIndent(): number {
        const subString = this.text.substring(this.currentIndex);
        const indentMatch = subString.match(/^ */);
        return indentMatch ? indentMatch[0].length : 0;
    }

    getPosition(): TokenPosition {
        return {
            fyl: this.filename,
            idx: this.currentIndex,
            lyn: this.currentLine,
            col: this.currentCol,
        }
    }
}

interface TokenPosition {
    fyl: string;
    idx: number;
    lyn: number;
    col: number;
}

interface IdentifierToken {
    kind: "ident";
    pos: TokenPosition;
    str: string;
}

interface WhitespaceToken {
    kind: "ws";
    pos: TokenPosition;
    nl: boolean;
}

interface OperatorToken {
    kind: "op";
    pos: TokenPosition;
    op: string;
}

interface BlockToken {
    kind: "block";
    pos: TokenPosition;
    start: string;
    end: string;
    items: SyntaxNode[];
}

interface BinaryExpressionToken {
    kind: "binary";
    pos: TokenPosition;
    prec: number;
    items: SyntaxNode[];
}

type SyntaxNode = IdentifierToken | WhitespaceToken | OperatorToken | BlockToken | BinaryExpressionToken;

interface TokenizerStackItem {
    pos: TokenPosition,
    char: string;
    indent: number;
    val: SyntaxNode[];
    prec: number;
    autoClose?: boolean;
}

type TokenizationErrorEntry = {
    pos: TokenPosition,
    style: "note" | "error",
    message: string,
};
type TokenizationError = {
    entries: TokenizationErrorEntry[],
    trace: TokenPosition[],
};
interface TokenizationResult {
    result: SyntaxNode[];
    errors: TokenizationError[];
}

const identifierRegex = /^[a-zA-Z0-9]$/;
const whitespaceRegex = /^\s$/;
const operatorChars = [..."~!@#$%^&*-=+|/<>"];

function tokenize(source: Source): TokenizationResult {
    let currentSyntaxNodes: SyntaxNode[] = [];
    const errors: TokenizationError[] = [];
    const parseStack: TokenizerStackItem[] = [];

    parseStack.push({ pos: source.getPosition(), char: "", indent: -1, val: currentSyntaxNodes, prec: 0 });

    while (source.peek()) {
        const start = source.getPosition();
        const firstChar = source.take();

        if (firstChar.match(identifierRegex)) {
            while (source.peek().match(identifierRegex)) {
                source.take();
            }
            currentSyntaxNodes.push({
                kind: "ident",
                pos: { fyl: source.filename, idx: start.idx, lyn: start.lyn, col: start.col },
                str: source.text.substring(start.idx, source.currentIndex),
            });
            continue;
        } else if (firstChar.match(whitespaceRegex)) {
            while (source.peek().match(whitespaceRegex)) {
                source.take();
            }
            currentSyntaxNodes.push({
                kind: "ws",
                pos: { fyl: source.filename, idx: start.idx, lyn: start.lyn, col: start.col },
                nl: source.text.substring(start.idx, source.currentIndex).includes("\n"),
            });
            continue;
        }
        
        let currentToken: string;
        if ("()[]{}:,;\"'`".includes(firstChar)) {
            currentToken = source.text.substring(start.idx, source.currentIndex);
        }else if(operatorChars.includes(firstChar)) {
            while (operatorChars.includes(source.peek())) {
                source.take();
            }
            currentToken = source.text.substring(start.idx, source.currentIndex);
        }else if(firstChar === "\\") {
            // todo: if '\()' token = '\()'
            currentToken = "\\";
        }else{
            currentToken = firstChar;
        }

        const cfg = config[currentToken];
        if (cfg?.style === "open") {
            const newBlockItems: SyntaxNode[] = [];
            currentSyntaxNodes.push({
                kind: "block",
                pos: { fyl: source.filename, idx: start.idx, lyn: start.lyn, col: start.col },
                start: currentToken,
                end: cfg.close ?? "",
                items: newBlockItems,
            });
            parseStack.push({
                pos: start,
                char: cfg.close ?? "",
                indent: source.currentLineIndentLevel,
                val: newBlockItems,
                prec: cfg.prec,
                autoClose: cfg.close == null,
            });
            currentSyntaxNodes = newBlockItems;
        } else if (cfg?.style === "close") {
            const currentIndent = source.currentLineIndentLevel;

            while (parseStack.length > 1) {
                const lastStackItem = parseStack.pop();
                if (!lastStackItem) unreachable();

                if (lastStackItem.char === currentToken && lastStackItem.indent === currentIndent) {
                    currentSyntaxNodes = parseStack[parseStack.length - 1]!.val;
                    break;
                }

                if (lastStackItem.indent < currentIndent) {
                    errors.push({
                        entries: [{
                            message: "extra close bracket",
                            style: "error",
                            pos: start,
                        }],
                        trace: [...referenceTrace],
                    });
                    parseStack.push(lastStackItem);
                    break;
                } else {
                    if (!lastStackItem.autoClose) {
                        errors.push({
                            entries: [{
                                message: "open bracket missing close bracket",
                                style: "error",
                                pos: lastStackItem.pos,
                            }, {
                                message: `expected ${JSON.stringify(lastStackItem.char)} indent '${lastStackItem.indent}', got ${JSON.stringify(currentToken)} indent '${currentIndent}'`,
                                style: "note",
                                pos: start,
                            }],
                            trace: [...referenceTrace],
                        });
                    }
                    currentSyntaxNodes = parseStack[parseStack.length - 1]!.val;
                }
            }
        } else if (cfg?.style === "join") {
            const operatorPrecedence = cfg.prec;
            let targetCommaBlock: TokenizerStackItem | undefined;

            while (parseStack.length > 0) {
                const lastStackItem = parseStack[parseStack.length - 1]!;

                if (lastStackItem.prec === operatorPrecedence) {
                    targetCommaBlock = lastStackItem;
                    break;
                } else if (lastStackItem.prec < operatorPrecedence) {
                    targetCommaBlock = {
                        pos: start,
                        char: currentToken,
                        val: [...lastStackItem.val],
                        indent: lastStackItem.indent,
                        autoClose: true,
                        prec: operatorPrecedence,
                    };
                    parseStack.push(targetCommaBlock);
                    lastStackItem.val.splice(0, lastStackItem.val.length, {
                        kind: "binary",
                        pos: start,
                        prec: operatorPrecedence,
                        items: targetCommaBlock.val,
                    });
                    break;
                } else {
                    if (!lastStackItem.autoClose) {
                        errors.push({
                            entries: [{
                                message: "item is never closed.",
                                style: "error",
                                pos: lastStackItem.pos,
                            }, {
                                message: "automatically closed here.",
                                style: "note",
                                pos: start,
                            }],
                            trace: [...referenceTrace],
                        });
                    }
                    parseStack.pop();
                }
            }

            if (!targetCommaBlock) {
                throw new Error("Unreachable: No target block found for comma/semicolon.");
            }

            currentSyntaxNodes = parseStack[parseStack.length - 1]!.val;
            currentSyntaxNodes.push({
                kind: "op",
                pos: start,
                op: currentToken,
            });
        } else {
            errors.push({
                entries: [{
                    message: "bad token "+JSON.stringify(currentToken),
                    style: "error",
                    pos: start,
                }],
                trace: [...referenceTrace],
            });
        }
    }

    return { result: parseStack[0]!.val, errors };
}

interface RenderConfig {
    indent: string;
    style?: "s";
}

function renderEntityList(config: RenderConfig, entities: SyntaxNode[], level: number, isTopLevel: boolean): string {
    let result = "";
    let needsDeeperIndent = false;
    let didInsertNewline = false;
    let lastNewlineIndex = -1;

    for (let i = 0; i < entities.length; i++) {
        const entity = entities[i]!;
        if (entity.kind === "ws" && entity.nl) {
            lastNewlineIndex = i;
        }
    }

    for (let i = 0; i < entities.length; i++) {
        const entity = entities[i]!;
        if (entity.kind === "ws") {
            if (entity.nl && !didInsertNewline) {
                needsDeeperIndent = !isTopLevel && i < lastNewlineIndex;
                didInsertNewline = true;
                result += "\n" + config.indent.repeat(level + (needsDeeperIndent ? 1 : 0));
            } else {
                result += " ";
            }
        } else {
            didInsertNewline = false;
            result += renderEntity(config, entity, level + (needsDeeperIndent ? 1 : 0), isTopLevel);
        }
    }
    return result;
}

function renderEntity(config: RenderConfig, entity: SyntaxNode, level: number, isTopLevel: boolean): string {
    if (config.style === "s") {
        if (entity.kind === "block") {
            return `(${JSON.stringify(entity.start + entity.end)} ` + renderEntityList(config, entity.items, level, false) + ")";
        } else if (entity.kind === "binary") {
            return "(binary " + renderEntityList(config, entity.items, level, isTopLevel) + ")";
        } else if (entity.kind === "ws") {
            throw new Error("Unreachable: Whitespace should be handled by renderEntityList.");
        } else if (entity.kind === "ident") {
            return "$" + entity.str;
        } else if (entity.kind === "op") {
            return JSON.stringify(entity.op);
        } else {
            return `(TODO $${(entity as {kind: string}).kind})`;
        }
    } else {
        if (entity.kind === "block") {
            return entity.start + renderEntityList(config, entity.items, level, false) + entity.end;
        } else if (entity.kind === "binary") {
            return renderEntityList(config, entity.items, level, isTopLevel);
        } else if (entity.kind === "ws") {
            throw new Error("Unreachable: Whitespace should be handled by renderEntityList.");
        } else if (entity.kind === "ident") {
            return entity.str;
        } else if (entity.kind === "op") {
            return entity.op;
        } else {
            return `%TODO<${(entity as {kind: string}).kind}>%`;
        }
    }
}

const colors = {
    red: "\x1b[31m",
    blue: "\x1b[34m",
    cyan: "\x1b[36m",
    bold: "\x1b[1m",
    reset: "\x1b[0m",
};

function prettyPrintErrors(source: Source, errors: TokenizationError[]): string {
    if (errors.length === 0) return "";

    const sourceLines = source.text.split('\n');
    let output = "";

    for (const error of errors) {
        output += "\n";

        for (const entry of error.entries) {
            const { pos, style, message } = entry;
            const color = style === 'error' ? colors.red : colors.blue;
            const bold = style === 'error' ? colors.bold : "";

            output += `${pos.fyl}:${pos.lyn}:${pos.col}: ${color}${bold}${style}${colors.reset}: ${message}${colors.reset}\n`;

            if (pos.fyl !== source.filename) continue;
            const line = sourceLines[pos.lyn - 1];
            if (line === undefined) continue;

            const lineNumberStr = String(pos.lyn);
            const gutterWidth = lineNumberStr.length;
            const emptyGutter = ` ${" ".repeat(gutterWidth)} ${colors.blue}|${colors.reset}`;
            const lineGutter = ` ${colors.cyan}${lineNumberStr}${colors.reset} ${colors.blue}|${colors.reset}`;

            output += `${lineGutter} ${line}\n`;

            const pointer = ' '.repeat(pos.col - 1) + '^';
            output += `${emptyGutter} ${color}${colors.bold}${pointer}${colors.reset}\n`;
        }
        if (error.trace.length > 0) {
            for(const line of error.trace) {
                output += `At ${line.fyl}:${line.lyn}:${line.col}\n`;
            }
        }
    }

    return output;
}

function renderTokenizedOutput(tokenizationResult: TokenizationResult, source: Source): string {
    const formattedCode = renderEntityList({ indent: "  " }, tokenizationResult.result, 0, true);
    const sExpression = renderEntityList({ indent: "  ", style: "s" }, tokenizationResult.result, 0, true);
    const prettyErrors = prettyPrintErrors(source, tokenizationResult.errors);
    
    return (
        `// formatted\n${formattedCode}\n\n` +
        `// s-expr:\n${sExpression}\n\n` +
        `// errors:\n${prettyErrors}`
    );
}
const src = `abc [
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
    (a, b => c, d = e, f => g, h)
] ghi`;
if (import.meta.main) {
    const sourceCode = new Source("src.qxc", src);

    const tokenized = tokenize(sourceCode);
    console.log(renderTokenizedOutput(tokenized, sourceCode));
}