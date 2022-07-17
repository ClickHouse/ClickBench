db.hits.stats().count;
db.hits.aggregate([{$match: {AdvEngineID: {$ne: 0}}}, {$count: 'c'}]);
db.hits.aggregate([{$group: {_id: null, s: {$sum: '$AdvEngineID'}, c: {$sum: 1}, a: {$avg: '$ResolutionWidth'}}}]);
db.hits.aggregate([{$addFields: {converted: { $toLong: "$UserID" }}}, {$group: {_id: null, a: {$avg: '$converted'}}}]);
db.hits.aggregate([{ $group: { _id: '$UserID' } }, { $count: 'value' }, { $project: { key: null, value: 1, } }], {allowDiskUse: true});
db.hits.aggregate([{ $group: { _id: '$SearchPhrase' } }, { $count: 'value' }, { $project: { key: null, value: 1, } }], {allowDiskUse: true});
db.hits.aggregate([{$group: {_id: null, min: {$min: '$EventDate'}, max: {$max: '$EventDate'}}}]);
db.hits.aggregate([{$match: {AdvEngineID: {$ne: 0}}}, { $group: { _id: '$AdvEngineID', c: {$sum: 1} } }, { $sort: { c: -1 } }]);

//db.hits.aggregate([{ $group: { _id: {u: '$UserID', r: '$RegionID'} } }, { $count: 'value' }, { $group: { _id: '$r', c: {$sum: 1} } }, { $sort: {c: -1} }, { $limit: 10 }], {allowDiskUse: true});

SELECT RegionID, COUNT(DISTINCT UserID) AS u FROM hits GROUP BY RegionID ORDER BY u DESC LIMIT 10;
