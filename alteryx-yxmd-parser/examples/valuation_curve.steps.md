# Valuation Curve Widening
tools: 7, not fully described: 1

1. [1] Input odbc:DSN=ValuationsDW;UID=svc;PWD=***|||SELECT DealID, AsOfDate, Tenor, Rate FROM dbo.Curves WHERE AsOfDate >= '2026-01-01' [RecordLimit=1000]   -> Output:2
     last-run cols: DealID:V_String, AsOfDate:Date, Tenor:Int32, Rate:Double
2. [2] Sort by DealID Ascending, Tenor Ascending   <- Input:1   -> Output:3
3. [3] MultiRow: RateDelta = [Rate] - [Row-1:Rate] [Double] partition by DealID   <- Input:2   -> Output:4,7,5   !! ORDER-DEPENDENT (last sort: [2])
4. [4] CrossTab pivot Rate by Tenor (Sum) group by DealID   <- Input:3   -> Output:6
5. [5] SpatialMatch (UNKNOWN TOOL) <Configuration><MatchType>Intersects</MatchType><TargetField>Geo</TargetField></Configuration>   <- Targets:3
6. [7] Output C:\out\deltas.csv   <- Input:3
7. [6] Output odbc:DSN=ValuationsDW|dbo.CurveWide [Overwrite]   <- Input:4
