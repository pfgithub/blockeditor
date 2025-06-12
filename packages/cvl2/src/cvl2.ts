function unreachable(): never {
    throw new Error("unreachable");
}

class Source {
    public text: string;
    public currentIndex: number;
    public currentLine: number;
    public currentCol: number;
    public filename: string;
    public currentLineIndentLevel: number;

    constructor(text: string) {
        this.text = text;
        this.currentIndex = 0;
        this.currentLine = 1;
        this.currentCol = 1;
        this.filename = "file";
        this.calculateIndent();
    }

    public peek(): string {
        return this.text[this.currentIndex] ?? "";
    }

    public take(): string {
        const character = this.peek();
        this.currentIndex += character.length;

        if (character === "\n") {
            this.currentLine += 1;
            this.currentCol = 1;
            this.calculateIndent();
        } else {
            this.currentCol += character.length;
        }
        return character;
    }

    private calculateIndent(): void {
        const subString = this.text.substring(this.currentIndex);
        const indentMatch = subString.match(/^ */);
        this.currentLineIndentLevel = indentMatch ? indentMatch[0].length : 0;
    }
}

interface TokenPosition {
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
    idx: number;
    lyn: number;
    col: number;
    char: string;
    indent: number;
    val: SyntaxNode[];
    prec: number;
    autoClose?: boolean;
}

interface TokenizationResult {
    result: SyntaxNode[];
    errors: (string | string[])[];
}

function tokenize(source: Source): TokenizationResult {
    let currentSyntaxNodes: SyntaxNode[] = [];
    const errors: (string | string[])[] = [];
    const parseStack: TokenizerStackItem[] = [];

    parseStack.push({ idx: 0, char: "", indent: -1, val: currentSyntaxNodes, prec: 0, lyn: 1, col: 1 });

    while (source.peek()) {
        const startIdx = source.currentIndex;
        const startLine = source.currentLine;
        const startCol = source.currentCol;
        const currentChar = source.take();

        const identifierRegex = /^[a-zA-Z0-9]$/;
        const whitespaceRegex = /^\s$/;
        const leftBrackets = ["(", "[", "{"];
        const rightBrackets = [")", "]", "}"];

        if (currentChar.match(identifierRegex)) {
            while (source.peek().match(identifierRegex)) {
                source.take();
            }
            currentSyntaxNodes.push({
                kind: "ident",
                pos: { idx: startIdx, lyn: startLine, col: startCol },
                str: source.text.substring(startIdx, source.currentIndex),
            });
        } else if (currentChar.match(whitespaceRegex)) {
            while (source.peek().match(whitespaceRegex)) {
                source.take();
            }
            currentSyntaxNodes.push({
                kind: "ws",
                pos: { idx: startIdx, lyn: startLine, col: startCol },
                nl: source.text.substring(startIdx, source.currentIndex).includes("\n"),
            });
        } else if (leftBrackets.includes(currentChar) || currentChar === ":") {
            const newBlockItems: SyntaxNode[] = [];
            currentSyntaxNodes.push({
                kind: "block",
                pos: { idx: startIdx, lyn: startLine, col: startCol },
                start: currentChar,
                end: currentChar === ":" ? "" : rightBrackets[leftBrackets.indexOf(currentChar)],
                items: newBlockItems,
            });
            parseStack.push({
                idx: startIdx,
                lyn: startLine,
                col: startCol,
                char: currentChar,
                indent: source.currentLineIndentLevel,
                val: newBlockItems,
                prec: currentChar === ":" ? 2 : 0,
                autoClose: currentChar === ":",
            });
            currentSyntaxNodes = newBlockItems;
        } else if (rightBrackets.includes(currentChar)) {
            const correspondingLeftBracket = leftBrackets[rightBrackets.indexOf(currentChar)];
            const currentIndent = source.currentLineIndentLevel;

            while (parseStack.length > 1) {
                const lastStackItem = parseStack.pop();
                if (!lastStackItem) unreachable();

                if (lastStackItem.char === correspondingLeftBracket && lastStackItem.indent === currentIndent) {
                    currentSyntaxNodes = parseStack[parseStack.length - 1].val;
                    break;
                }

                if (lastStackItem.indent < currentIndent) {
                    errors.push(`${source.filename}:${startLine}:${startCol} error: extra close bracket`);
                    parseStack.push(lastStackItem);
                    break;
                } else {
                    if (!lastStackItem.autoClose) {
                        errors.push([
                            `${source.filename}:${lastStackItem.lyn}:${lastStackItem.col} error: open bracket missing close bracket`,
                            `${source.filename}:${startLine}:${startCol} note: expected for '${lastStackItem.char}' indent '${lastStackItem.indent}', got '${currentChar}' indent '${currentIndent}'`,
                        ]);
                    }
                    currentSyntaxNodes = parseStack[parseStack.length - 1].val;
                }
            }
        } else if (currentChar === "," || currentChar === ";") {
            const operatorPrecedence = 1;
            let targetCommaBlock: TokenizerStackItem | undefined;

            while (parseStack.length > 0) {
                const lastStackItem = parseStack[parseStack.length - 1];

                if (lastStackItem.prec === operatorPrecedence) {
                    targetCommaBlock = lastStackItem;
                    break;
                } else if (lastStackItem.prec < operatorPrecedence) {
                    targetCommaBlock = {
                        idx: startIdx,
                        lyn: startLine,
                        col: startCol,
                        char: currentChar,
                        val: [...lastStackItem.val],
                        indent: lastStackItem.indent,
                        autoClose: true,
                        prec: operatorPrecedence,
                    };
                    parseStack.push(targetCommaBlock);
                    lastStackItem.val.splice(0, lastStackItem.val.length, {
                        kind: "binary",
                        pos: { idx: startIdx, lyn: startLine, col: startCol },
                        prec: operatorPrecedence,
                        items: targetCommaBlock.val,
                    });
                    break;
                } else {
                    if (!lastStackItem.autoClose) {
                        errors.push([
                            `${source.filename}:${startLine}:${startCol} auto-closing non auto-closeable item.`,
                            `${source.filename}:${lastStackItem.lyn}:${lastStackItem.col} note: opened here`,
                        ]);
                    }
                    parseStack.pop();
                }
            }

            if (!targetCommaBlock) {
                throw new Error("Unreachable: No target block found for comma/semicolon.");
            }

            currentSyntaxNodes = parseStack[parseStack.length - 1].val;
            currentSyntaxNodes.push({
                kind: "op",
                pos: { idx: startIdx, lyn: startLine, col: startCol },
                op: currentChar,
            });
        } else {
            errors.push(`${source.filename}:${startLine}:${startCol} error: bad char ${JSON.stringify(currentChar)}`);
        }
    }

    return { result: parseStack[0].val, errors };
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
        const entity = entities[i];
        if (entity.kind === "ws" && entity.nl) {
            lastNewlineIndex = i;
        }
    }

    for (let i = 0; i < entities.length; i++) {
        const entity = entities[i];
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

function renderTokenizedOutput(tokenizationResult: TokenizationResult, source: Source): string {
    const formattedCode = renderEntityList({ indent: "  " }, tokenizationResult.result, 0, true);
    const sExpression = renderEntityList({ indent: "  ", style: "s" }, tokenizationResult.result, 0, true);
    const errorsJson = JSON.stringify(tokenizationResult.errors, null, 2);

    return (
        `// formatted\n${formattedCode}\n\n` +
        `// s-expr:\n${sExpression}\n\n` +
        `// errors:\n${errorsJson}`
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
] ghi`;
if (import.meta.main) {
    const sourceCode = new Source(src);

    const tokenized = tokenize(sourceCode);
    console.log(renderTokenizedOutput(tokenized, sourceCode));
}