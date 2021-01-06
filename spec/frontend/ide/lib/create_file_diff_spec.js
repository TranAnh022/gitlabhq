const mapLines = (content, mapFn) =>
  content
    .split('\n')
    .map(mapFn)
    .join('\n');
    const expectedChunkHead = lineCount => `--- /dev/null
${mapLines(TEXT, line => `+${line}`)}
    const expectedChunkHead = lineCount => `--- a/${PATH}
${mapLines(TEXT, line => `-${line}`)}