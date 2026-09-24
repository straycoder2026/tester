/*
  LAB ONLY. Run in query window 3 after sessions 1 and 2 are active.
  Run the cycle at least twice, with 30+ seconds of blocking, to meet lab rules.
*/
EXEC xt.usp_MonitorCycle;

SELECT TOP (100) *
FROM xt.vw_TerminationDashboard
ORDER BY CandidateId DESC;

SELECT TOP (100) *
FROM xt.TerminationRuleEvaluation
ORDER BY EvaluationId DESC;

/*
  Expected audit result:
    CandidateState = Proposed
    ActionStatus    = Proposed

  For an automatic SIMULATION test only:
    1. Deploy termination-settings.json with enabled=true and simulationOnly=true.
    2. UPDATE xt.ConfigTermination SET OperatingMode='Automatic' WHERE ConfigId=1;
    3. Start fresh session 1 and session 2 executions.
    4. Run this monitor cycle until eligible.
    5. Expected ActionStatus = Simulated; timeout.exe remains running.
*/

