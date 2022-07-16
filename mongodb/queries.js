db.hits.stats().count;
db.hits.explain(true).aggregate([{$match: {AdvEngineID: {$ne: 0}}}, {$group: {_id: null, count: {$sum: 1}}}]);
db.hits.explain(true).aggregate([{$group: {_id: null, count: {$sum: 1}}}]);
