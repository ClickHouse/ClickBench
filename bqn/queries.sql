util←•Import •wdpath∾"/util.bqn"⋄util.NumRows@
util←•Import •wdpath∾"/util.bqn"⋄+´0≠util.LoadF"AdvEngineID"
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄a←util.LoadF"AdvEngineID"⋄w←util.LoadF"ResolutionWidth"⋄⟨+´a,≠a,(+´w)÷≠w⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄u←util.LoadF"UserID"⋄(+´u)÷≠u}@
util←•Import •wdpath∾"/util.bqn"⋄≠⍷util.LoadF"UserID"
util←•Import •wdpath∾"/util.bqn"⋄≠⍷util.LoadS"SearchPhrase"
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄e←util.LoadF"EventDate"⋄⟨⌊´e,⌈´e⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄a←util.LoadF"AdvEngineID"⋄k←(0≠a)/a⋄⟨ks,cs⟩←(≠⊣)util._groupBy k⋄o←⍒cs⋄⟨o⊏ks,o⊏cs⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄r←util.LoadF"RegionID"⋄u←util.LoadF"UserID"⋄⟨ks,ds⟩←{≠⍷u⊏˜𝕩}util._groupBy r⋄t←util.TopN 10‿ds⋄⟨t⊏ks,t⊏ds⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄r←util.LoadF"RegionID"⋄a←util.LoadF"AdvEngineID"⋄w←util.LoadF"ResolutionWidth"⋄u←util.LoadF"UserID"⋄⟨ks,vs⟩←{i←𝕩⋄⟨+´a⊏˜i,≠i,(+´w⊏˜i)÷≠i,≠⍷u⊏˜i⟩}util._groupBy r⋄c←1⊑¨vs⋄t←util.TopN 10‿c⋄⟨t⊏ks,t⊏vs⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄m←util.LoadS"MobilePhoneModel"⋄u←util.LoadF"UserID"⋄mk←0<≠¨m⋄k←mk/m⋄u2←mk/u⋄⟨ks,ds⟩←{≠⍷u2⊏˜𝕩}util._groupBy k⋄t←util.TopN 10‿ds⋄⟨t⊏ks,t⊏ds⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄p←util.LoadF"MobilePhone"⋄m←util.LoadS"MobilePhoneModel"⋄u←util.LoadF"UserID"⋄mk←0<≠¨m⋄k←(mk/p)util.Pair(mk/m)⋄u2←mk/u⋄⟨ks,ds⟩←{≠⍷u2⊏˜𝕩}util._groupBy k⋄t←util.TopN 10‿ds⋄⟨t⊏ks,t⊏ds⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄s←util.LoadS"SearchPhrase"⋄k←(0<≠¨s)/s⋄⟨ks,cs⟩←(≠⊣)util._groupBy k⋄t←util.TopN 10‿cs⋄⟨t⊏ks,t⊏cs⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄s←util.LoadS"SearchPhrase"⋄u←util.LoadF"UserID"⋄mk←0<≠¨s⋄k←mk/s⋄u2←mk/u⋄⟨ks,ds⟩←{≠⍷u2⊏˜𝕩}util._groupBy k⋄t←util.TopN 10‿ds⋄⟨t⊏ks,t⊏ds⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄se←util.LoadF"SearchEngineID"⋄s←util.LoadS"SearchPhrase"⋄mk←0<≠¨s⋄k←(mk/se)util.Pair(mk/s)⋄⟨ks,cs⟩←(≠⊣)util._groupBy k⋄t←util.TopN 10‿cs⋄⟨t⊏ks,t⊏cs⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄u←util.LoadF"UserID"⋄⟨ks,cs⟩←(≠⊣)util._groupBy u⋄t←util.TopN 10‿cs⋄⟨t⊏ks,t⊏cs⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄u←util.LoadF"UserID"⋄s←util.LoadS"SearchPhrase"⋄⟨ks,cs⟩←(≠⊣)util._groupBy u util.Pair s⋄t←util.TopN 10‿cs⋄⟨t⊏ks,t⊏cs⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄u←util.LoadF"UserID"⋄s←util.LoadS"SearchPhrase"⋄⟨ks,cs⟩←(≠⊣)util._groupBy u util.Pair s⋄t←(10⌊≠ks)↑↕≠ks⋄⟨t⊏ks,t⊏cs⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄u←util.LoadF"UserID"⋄e←util.LoadF"EventTime"⋄s←util.LoadS"SearchPhrase"⋄mn←60|⌊e÷60⋄k←u util.Pair mn util.Pair s⋄⟨ks,cs⟩←(≠⊣)util._groupBy k⋄t←util.TopN 10‿cs⋄⟨t⊏ks,t⊏cs⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄u←util.LoadF"UserID"⋄≠(435090932899640449=u)/u}@
util←•Import •wdpath∾"/util.bqn"⋄+´"google"util.ContainsAny util.LoadS"URL"
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄u←util.LoadS"URL"⋄s←util.LoadS"SearchPhrase"⋄mk←("google"util.ContainsAny u)∧0<≠¨s⋄u2←mk/u⋄s2←mk/s⋄⟨ks,vs⟩←{i←𝕩⋄⟨util.LexMin u2⊏˜i,≠i⟩}util._groupBy s2⋄c←1⊑¨vs⋄t←util.TopN 10‿c⋄⟨t⊏ks,t⊏vs⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄u←util.LoadS"URL"⋄ti←util.LoadS"Title"⋄s←util.LoadS"SearchPhrase"⋄id←util.LoadF"UserID"⋄mk←("Google"util.ContainsAny ti)∧(¬".google."util.ContainsAny u)∧0<≠¨s⋄u2←mk/u⋄t2←mk/ti⋄s2←mk/s⋄i2←mk/id⋄⟨ks,vs⟩←{i←𝕩⋄⟨util.LexMin u2⊏˜i,util.LexMin t2⊏˜i,≠i,≠⍷i2⊏˜i⟩}util._groupBy s2⋄c←2⊑¨vs⋄t←util.TopN 10‿c⋄⟨t⊏ks,t⊏vs⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄u←util.LoadS"URL"⋄e←util.LoadF"EventTime"⋄mk←"google"util.ContainsAny u⋄10↑⍋mk/e}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄s←util.LoadS"SearchPhrase"⋄e←util.LoadF"EventTime"⋄mk←0<≠¨s⋄(10↑⍋mk/e)⊏mk/s}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄s←util.LoadS"SearchPhrase"⋄s2←(0<≠¨s)/s⋄(10↑⍋s2)⊏s2}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄s←util.LoadS"SearchPhrase"⋄e←util.LoadF"EventTime"⋄mk←0<≠¨s⋄(10↑⍋mk/e)⊏mk/s}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄c←util.LoadF"CounterID"⋄u←util.LoadS"URL"⋄l←≠¨u⋄mk←0<l⋄c2←mk/c⋄l2←mk/l⋄⟨ks,vs⟩←{i←𝕩⋄⟨(+´l2⊏˜i)÷≠i,≠i⟩}util._groupBy c2⋄cs←1⊑¨vs⋄ls←0⊑¨vs⋄kp←cs>100000⋄k2←kp/ks⋄l3←kp/ls⋄c3←kp/cs⋄t←util.TopN 25‿l3⋄⟨t⊏k2,t⊏l3,t⊏c3⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄ref←util.LoadS"Referer"⋄mk←0<≠¨ref⋄r2←mk/ref⋄SP←{pre𝕊s:(((≠pre)≤≠s)∧pre≡(≠pre)↑s)◶⟨s,(≠pre)↓s⟩@}⋄H←{s←"http://"SP𝕩⋄s↩"https://"SP s⋄s↩"www."SP s⋄(⊑s⊐'/')↑s}⋄k←H¨r2⋄l←≠¨r2⋄⟨ks,vs⟩←{i←𝕩⋄⟨(+´l⊏˜i)÷≠i,≠i,util.LexMin r2⊏˜i⟩}util._groupBy k⋄cs←1⊑¨vs⋄kp←cs>100000⋄k2←kp/ks⋄v2←kp/vs⋄l2←0⊑¨v2⋄t←util.TopN 25‿l2⋄⟨t⊏k2,t⊏v2⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄w←util.LoadF"ResolutionWidth"⋄(+´w)+(≠w)×↕90}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄se←util.LoadF"SearchEngineID"⋄ci←util.LoadF"ClientIP"⋄s←util.LoadS"SearchPhrase"⋄ir←util.LoadF"IsRefresh"⋄w←util.LoadF"ResolutionWidth"⋄mk←0<≠¨s⋄k←(mk/se)util.Pair(mk/ci)⋄i2←mk/ir⋄w2←mk/w⋄⟨ks,vs⟩←{i←𝕩⋄⟨≠i,+´i2⊏˜i,(+´w2⊏˜i)÷≠i⟩}util._groupBy k⋄cs←0⊑¨vs⋄t←util.TopN 10‿cs⋄⟨t⊏ks,t⊏vs⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄wi←util.LoadF"WatchID"⋄ci←util.LoadF"ClientIP"⋄s←util.LoadS"SearchPhrase"⋄ir←util.LoadF"IsRefresh"⋄w←util.LoadF"ResolutionWidth"⋄mk←0<≠¨s⋄k←(mk/wi)util.Pair(mk/ci)⋄i2←mk/ir⋄w2←mk/w⋄⟨ks,vs⟩←{i←𝕩⋄⟨≠i,+´i2⊏˜i,(+´w2⊏˜i)÷≠i⟩}util._groupBy k⋄cs←0⊑¨vs⋄t←util.TopN 10‿cs⋄⟨t⊏ks,t⊏vs⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄wi←util.LoadF"WatchID"⋄ci←util.LoadF"ClientIP"⋄ir←util.LoadF"IsRefresh"⋄w←util.LoadF"ResolutionWidth"⋄k←wi util.Pair ci⋄⟨ks,vs⟩←{i←𝕩⋄⟨≠i,+´ir⊏˜i,(+´w⊏˜i)÷≠i⟩}util._groupBy k⋄cs←0⊑¨vs⋄t←util.TopN 10‿cs⋄⟨t⊏ks,t⊏vs⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄u←util.LoadS"URL"⋄⟨ks,cs⟩←(≠⊣)util._groupBy u⋄t←util.TopN 10‿cs⋄⟨t⊏ks,t⊏cs⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄u←util.LoadS"URL"⋄⟨ks,cs⟩←(≠⊣)util._groupBy u⋄t←util.TopN 10‿cs⋄⟨(≠t)⥊1,t⊏ks,t⊏cs⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄ci←util.LoadF"ClientIP"⋄⟨ks,cs⟩←(≠⊣)util._groupBy ci⋄t←util.TopN 10‿cs⋄k←t⊏ks⋄⟨k,k-1,k-2,k-3,t⊏cs⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄ci←util.LoadF"CounterID"⋄ed←util.LoadF"EventDate"⋄dh←util.LoadF"DontCountHits"⋄ir←util.LoadF"IsRefresh"⋄u←util.LoadS"URL"⋄mk←(62=ci)∧(ed≥15887)∧(ed≤15917)∧(0=dh)∧(0=ir)∧0<≠¨u⋄u2←mk/u⋄⟨ks,cs⟩←(≠⊣)util._groupBy u2⋄t←util.TopN 10‿cs⋄⟨t⊏ks,t⊏cs⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄ci←util.LoadF"CounterID"⋄ed←util.LoadF"EventDate"⋄dh←util.LoadF"DontCountHits"⋄ir←util.LoadF"IsRefresh"⋄ti←util.LoadS"Title"⋄mk←(62=ci)∧(ed≥15887)∧(ed≤15917)∧(0=dh)∧(0=ir)∧0<≠¨ti⋄t2←mk/ti⋄⟨ks,cs⟩←(≠⊣)util._groupBy t2⋄t←util.TopN 10‿cs⋄⟨t⊏ks,t⊏cs⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄ci←util.LoadF"CounterID"⋄ed←util.LoadF"EventDate"⋄ir←util.LoadF"IsRefresh"⋄il←util.LoadF"IsLink"⋄id←util.LoadF"IsDownload"⋄u←util.LoadS"URL"⋄mk←(62=ci)∧(ed≥15887)∧(ed≤15917)∧(0=ir)∧(0≠il)∧(0=id)⋄u2←mk/u⋄⟨ks,cs⟩←(≠⊣)util._groupBy u2⋄o←⍒cs⋄sl←(10⌊0⌈(≠o)-1000)↑1000↓o⋄⟨sl⊏ks,sl⊏cs⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄ci←util.LoadF"CounterID"⋄ed←util.LoadF"EventDate"⋄ir←util.LoadF"IsRefresh"⋄ts←util.LoadF"TraficSourceID"⋄se←util.LoadF"SearchEngineID"⋄ae←util.LoadF"AdvEngineID"⋄re←util.LoadS"Referer"⋄u←util.LoadS"URL"⋄mk←(62=ci)∧(ed≥15887)∧(ed≤15917)∧(0=ir)⋄t2←mk/ts⋄s2←mk/se⋄a2←mk/ae⋄r2←mk/re⋄u2←mk/u⋄src←((0=s2)∧0=a2){𝕨?𝕩;""}¨r2⋄k←t2 util.Pair s2 util.Pair a2 util.Pair src util.Pair u2⋄⟨ks,cs⟩←(≠⊣)util._groupBy k⋄o←⍒cs⋄sl←(10⌊0⌈(≠o)-1000)↑1000↓o⋄⟨sl⊏ks,sl⊏cs⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄ci←util.LoadF"CounterID"⋄ed←util.LoadF"EventDate"⋄ir←util.LoadF"IsRefresh"⋄ts←util.LoadF"TraficSourceID"⋄rh←util.LoadF"RefererHash"⋄uh←util.LoadF"URLHash"⋄mk←(62=ci)∧(ed≥15887)∧(ed≤15917)∧(0=ir)∧((ts=¯1)∨(ts=6))∧rh=3594120000172545465⋄k←(mk/uh)util.Pair(mk/ed)⋄⟨ks,cs⟩←(≠⊣)util._groupBy k⋄o←⍒cs⋄sl←(10⌊0⌈(≠o)-100)↑100↓o⋄⟨sl⊏ks,sl⊏cs⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄ci←util.LoadF"CounterID"⋄ed←util.LoadF"EventDate"⋄ir←util.LoadF"IsRefresh"⋄dh←util.LoadF"DontCountHits"⋄uh←util.LoadF"URLHash"⋄ww←util.LoadF"WindowClientWidth"⋄wh←util.LoadF"WindowClientHeight"⋄mk←(62=ci)∧(ed≥15887)∧(ed≤15917)∧(0=ir)∧(0=dh)∧uh=2868770270353813622⋄k←(mk/ww)util.Pair(mk/wh)⋄⟨ks,cs⟩←(≠⊣)util._groupBy k⋄o←⍒cs⋄sl←(10⌊0⌈(≠o)-10000)↑10000↓o⋄⟨sl⊏ks,sl⊏cs⟩}@
util←•Import •wdpath∾"/util.bqn"⋄{𝕤⋄ci←util.LoadF"CounterID"⋄ed←util.LoadF"EventDate"⋄ir←util.LoadF"IsRefresh"⋄dh←util.LoadF"DontCountHits"⋄et←util.LoadF"EventTime"⋄mk←(62=ci)∧(ed≥15900)∧(ed≤15901)∧(0=ir)∧(0=dh)⋄m←60×⌊(mk/et)÷60⋄⟨ks,cs⟩←(≠⊣)util._groupBy m⋄o←⍋ks⋄sl←(10⌊0⌈(≠o)-1000)↑1000↓o⋄⟨sl⊏ks,sl⊏cs⟩}@
