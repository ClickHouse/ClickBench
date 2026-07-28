hits.count()
hits[hits['AdvEngineID'] != 0].count()
(hits['AdvEngineID'].sum(), hits.shape[0], hits['ResolutionWidth'].mean())
hits['UserID'].mean()
hits['UserID'].nunique()
hits['SearchPhrase'].nunique()
(hits['EventDate'].min(), hits['EventDate'].max())
hits[hits['AdvEngineID'] != 0].groupby('AdvEngineID').size().rename('c').reset_index().sort_values('c', ascending=False)
hits.groupby('RegionID')['UserID'].nunique().nlargest(10)
hits.groupby('RegionID').agg(AdvEngineID=('AdvEngineID', 'sum'), c=('WatchID', 'size'), ResolutionWidth=('ResolutionWidth', 'mean'), UserID=('UserID', nunique)).nlargest(10, 'c')
hits[hits['MobilePhoneModel'] != ''].groupby('MobilePhoneModel')['UserID'].nunique().nlargest(10)
hits[hits['MobilePhoneModel'] != ''].groupby(['MobilePhone', 'MobilePhoneModel'])['UserID'].nunique().nlargest(10)
hits[hits['SearchPhrase'] != ''].groupby('SearchPhrase').size().nlargest(10)
hits[hits['SearchPhrase'] != ''].groupby('SearchPhrase')['UserID'].nunique().nlargest(10)
hits[hits['SearchPhrase'] != ''].groupby(['SearchEngineID', 'SearchPhrase']).size().nlargest(10)
hits.groupby('UserID').size().nlargest(10)
hits.groupby(['UserID', 'SearchPhrase']).size().nlargest(10)
hits.groupby(['UserID', 'SearchPhrase']).size().head(10)
hits.groupby([hits['UserID'], hits['EventTime'].dt.minute, 'SearchPhrase']).size().nlargest(10)
hits[hits['UserID'] == 435090932899640449]
hits[hits['URL'].str.contains('google')].shape[0]
hits[hits['URL'].str.contains('google') & (hits['SearchPhrase'] != '')].groupby('SearchPhrase').agg(URL=('URL', 'min'), c=('SearchPhrase', 'size')).nlargest(10, 'c')
hits[hits['Title'].str.contains('Google') & ~hits['URL'].str.contains('.google.') & (hits['SearchPhrase'] != '')].groupby('SearchPhrase').agg(URL=('URL', 'min'), Title=('Title', 'min'), c=('SearchPhrase', 'size'), UserID=('UserID', nunique)).nlargest(10, 'c')
hits[hits['URL'].str.contains('google')].nsmallest(10, 'EventTime')
hits[hits['SearchPhrase'] != ''].nsmallest(10, 'EventTime').compute()[['SearchPhrase']]
hits[hits['SearchPhrase'] != ''][['SearchPhrase']].sort_values('SearchPhrase').head(10, npartitions=-1)
hits[hits['SearchPhrase'] != ''].sort_values(['EventTime', 'SearchPhrase']).head(10, npartitions=-1)[['SearchPhrase']]
hits[hits['URL'] != ''].assign(l=hits['URL'].str.len()).groupby('CounterID').agg(l=('l', 'mean'), c=('URL', 'size')).query('c > 100000').nlargest(25, 'l')
hits[hits['Referer'] != ''].assign(k=lambda d: d['Referer'].str.extract('^https?://(?:www\\.)?([^/]+)/.*$')[0], l=lambda d: d['Referer'].str.len()).groupby('k').agg(l=('l', 'mean'), c=('Referer', 'size'), min_referer=('Referer', 'min')).query('c > 100000').nlargest(25, 'l')
[(hits['ResolutionWidth'] + i).sum() for i in range(90)]
hits[hits['SearchPhrase'] != ''].groupby(['SearchEngineID', 'ClientIP']).agg(c=('SearchEngineID', 'size'), IsRefreshSum=('IsRefresh', 'sum'), AvgResolutionWidth=('ResolutionWidth', 'mean')).nlargest(10, 'c')
hits[hits['SearchPhrase'] != ''].groupby(['WatchID', 'ClientIP']).agg(c=('WatchID', 'size'), IsRefreshSum=('IsRefresh', 'sum'), AvgResolutionWidth=('ResolutionWidth', 'mean')).nlargest(10, 'c')
hits.groupby(['WatchID', 'ClientIP']).agg(c=('WatchID', 'size'), IsRefreshSum=('IsRefresh', 'sum'), AvgResolutionWidth=('ResolutionWidth', 'mean')).nlargest(10, 'c')
hits.groupby('URL').size().rename('c').nlargest(10).reset_index()
hits.groupby('URL').size().rename('c').nlargest(10).reset_index()
hits.assign(**{f'ClientIP_minus_{i}': hits['ClientIP'] - i for i in range(1, 4)}).groupby(['ClientIP', 'ClientIP_minus_1', 'ClientIP_minus_2', 'ClientIP_minus_3']).size().rename('c').nlargest(10).reset_index()
hits[(hits['CounterID'] == 62) & (hits['EventDate'] >= '2013-07-01') & (hits['EventDate'] <= '2013-07-31') & (hits['DontCountHits'] == 0) & (hits['IsRefresh'] == 0) & (hits['URL'] != '')].groupby('URL').size().nlargest(10)
hits[(hits['CounterID'] == 62) & (hits['EventDate'] >= '2013-07-01') & (hits['EventDate'] <= '2013-07-31') & (hits['DontCountHits'] == 0) & (hits['IsRefresh'] == 0) & (hits['Title'] != '')].groupby('Title').size().nlargest(10)
hits[(hits['CounterID'] == 62) & (hits['EventDate'] >= '2013-07-01') & (hits['EventDate'] <= '2013-07-31') & (hits['IsRefresh'] == 0) & (hits['IsLink'] != 0) & (hits['IsDownload'] == 0)].groupby('URL').size().rename('PageViews').nlargest(1010).reset_index().compute().iloc[1000:1010]
hits[(hits['CounterID'] == 62) & (hits['EventDate'] >= '2013-07-01') & (hits['EventDate'] <= '2013-07-31') & (hits['IsRefresh'] == 0)].assign(Src=lambda d: d['Referer'].where((d['SearchEngineID'] == 0) & (d['AdvEngineID'] == 0), '')).groupby(['TraficSourceID', 'SearchEngineID', 'AdvEngineID', 'Src', 'URL']).size().rename('PageViews').nlargest(1010).reset_index().compute().iloc[1000:1010]
hits[(hits['CounterID'] == 62) & (hits['EventDate'] >= '2013-07-01') & (hits['EventDate'] <= '2013-07-31') & (hits['IsRefresh'] == 0) & hits['TraficSourceID'].isin([-1, 6]) & (hits['RefererHash'] == 3594120000172545465)].groupby(['URLHash', 'EventDate']).size().rename('PageViews').nlargest(110).reset_index().compute().iloc[100:110]
hits[(hits['CounterID'] == 62) & (hits['EventDate'] >= '2013-07-01') & (hits['EventDate'] <= '2013-07-31') & (hits['IsRefresh'] == 0) & (hits['DontCountHits'] == 0) & (hits['URLHash'] == 2868770270353813622)].groupby(['WindowClientWidth', 'WindowClientHeight']).size().rename('PageViews').nlargest(10010).reset_index().compute().iloc[10000:10010]
hits[(hits['CounterID'] == 62) & (hits['EventDate'] >= '2013-07-14') & (hits['EventDate'] <= '2013-07-15') & (hits['IsRefresh'] == 0) & (hits['DontCountHits'] == 0)].assign(M=lambda d: d['EventTime'].dt.floor('min')).groupby('M').size().rename('PageViews').reset_index().compute().sort_values('M').iloc[1000:1010]
