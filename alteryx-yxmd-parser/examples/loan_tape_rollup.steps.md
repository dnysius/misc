# Loan Tape Region Rollup
params: User.MinBalance=10000

1. [7] Input C:\Deals\customers.xlsx|||Sheet1   -> Output:2
     cols: CustID:V_String, CustomerName:V_WString, Region:V_String
2. [12] Input C:\Deals\loan_tape.csv   -> Output:5
     cols: LoanID:V_String, CustomerID:V_String, Balance:Double, Rate:Double, Status:V_String, OriginationDate:Date
3. [21] TextInput (LoanID, CustomerID, OutstandingBalance, Rate, Status): ADJ-001, C100, 250000, 4.5, Performing; ADJ-002, C200, 75000, 6.1, Performing   -> Output:22   // Deal team overrides
4. [5] Select: rename Balance->OutstandingBalance; cast Rate FixedDecimal(19.6); drop OriginationDate; drop unlisted   <- Input:12   -> Output:9   // Tidy columns
5. [9] Filter: [Status] = "Performing" AND [OutstandingBalance] > %User.MinBalance%   <- Input:5   -> True:22   // Performing loans only
6. [22] Union ByName, keep All columns   <- #1:9 #2:21   -> Output:14
7. [14] Formula: AnnualInterest = [OutstandingBalance] * [Rate] / 100; SizeBucket = IIF([OutstandingBalance] > 1000000, "Large", "Small"); AsOfMonth = DateTimeFormat(DateTimeToday(), "%Y-%m")   <- Input:22   -> Output:2
8. [2] Join on CustomerID = CustID; drop Right_CustID; keep unlisted   <- Left:14 Right:7   -> Join:25 Left:40
9. [25] Unique on LoanID (first row per key wins)   <- Input:2   -> Unique:30
10. [40] Output C:\Deals\out\unmatched_loans.csv   <- Input:2   // Loans with no customer record
11. [30] Macro:Cleanse {'Check Box (84)': 'True', 'Check Box (117)': 'False', 'List Box (11)': 'LoanID,CustomerName', 'Check Box (164)': 'True', 'Check Box (165)': 'False', 'Check Box (166)': 'True'}   <- Input:25   -> Output:31
12. [31] Summarize group by Region, SizeBucket: Sum(OutstandingBalance) as TotalBalance, Sum(AnnualInterest) as TotalInterest, Count(LoanID) as LoanCount, Avg(Rate) as AvgRate   <- Input:30   -> Output:32
13. [32] Sort by Region Ascending, TotalBalance Descending   <- Input:31   -> Output:3
14. [3] Output C:\Deals\out\region_rollup.csv   <- Input:32

skipped (disabled container): [51] JupyterCode
