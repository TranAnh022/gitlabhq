const cleanTwoFilesPatch = text => text.replace(/^(=+\s*)/, '');
const endsWithNewLine = val => !val || val[val.length - 1] === NEW_LINE;
const addEndingNewLine = val => (endsWithNewLine(val) ? val : val + NEW_LINE);
const removeEndingNewLine = val => (endsWithNewLine(val) ? val.substr(0, val.length - 1) : val);
    .map(line => `${prefix}${line}`)