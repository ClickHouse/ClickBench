// runs with node <input>
const fs = require("fs");
const inputFile = process.argv[2];
const inputContent = fs.readFileSync(inputFile, "utf-8");
const res = {};
inputContent.split(/\r?\n/).forEach((line) => {
  if (line.length == 0) {
    return;
  }
  parsed = JSON.parse(line);
  res[parsed.q + "_" + parsed.it] = parsed.ok == 1 ? parsed.t / 1000.0 : null;
});
console.log("[");
for (let i = 0; i < 43; ++i) {
  delim = i == 42 ? "" : ",";
  line =
    "[" +
    res[i + "_0"] +
    "," +
    res[i + "_1"] +
    "," +
    res[i + "_2"] +
    "]" +
    delim;
  console.log(line);
}
console.log("]");
