const iterations = 3;

// `col` need in queries to make lookups so define before load
let collectionName = "hits"
let col = db.getCollection(collectionName);

load("./queries.js");

for (let i = 0; i < queries.length; i++) {
  for (let j = 0; j < iterations; ++j) {
    start = new Date();
    try {
      res = col.aggregate(queries[i], { allowDiskUse: true }).toArray();
      print(
        EJSON.stringify({
          q: i,
          it: j,
          ok: 1,
          t: new Date().getTime() - start.getTime(),
          res: res,
        })
      );
    } catch (e) {
      print(
        EJSON.stringify({
          q: i,
          it: j,
          ok: 0,
          t: new Date().getTime() - start.getTime(),
          res: e,
        })
      );
    }
  }
}
