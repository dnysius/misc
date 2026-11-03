# Valuation Curve Widening

1. [1] Input odbc:DSN=ValuationsDW;UID=svc|||SELECT DealID, AsOfDate, Tenor, Rate FROM dbo.Curves WHERE AsOfDate >= '2026-01-01'   -> Output:2
     cols: DealID:V_String, AsOfDate:Date, Tenor:Int32, Rate:Double
2. [2] Sort by DealID Ascending, Tenor Ascending   <- Input:1   -> Output:3
3. [3] MultiRow: RateDelta = [Rate] - [Row-1:Rate] partition by DealID   <- Input:2   -> Output:4,7,5
4. [4] CrossTab pivot Rate by Tenor (Sum) group by DealID   <- Input:3   -> Output:6
5. [5] SpatialMatch (UNKNOWN TOOL) <Configuration><MatchType>Intersects</MatchType><TargetField>Geo</TargetField></Configuration>   <- Targets:3
6. [7] Output C:\out\deltas.csv   <- Input:3
7. [6] Output odbc:DSN=ValuationsDW|dbo.CurveWide   <- Input:4
