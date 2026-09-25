/*
  Blocking monitor and constrained termination workflow.
  Safe defaults: AuditOnly mode, termination disabled, forced termination disabled.
  Run after 001_install.sql in the same DBA/monitor database.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID(N'xt.ConfigTermination', N'U') IS NULL
BEGIN
    CREATE TABLE xt.ConfigTermination
    (
        ConfigId                   tinyint       NOT NULL CONSTRAINT PK_ConfigTermination PRIMARY KEY,
        Enabled                    bit           NOT NULL CONSTRAINT DF_ConfigTermination_Enabled DEFAULT (0),
        OperatingMode              varchar(16)   NOT NULL CONSTRAINT DF_ConfigTermination_Mode DEFAULT ('AuditOnly'),
        MinimumExecutionSeconds    int           NOT NULL CONSTRAINT DF_ConfigTermination_Execution DEFAULT (600),
        MinimumBlockedSeconds      int           NOT NULL CONSTRAINT DF_ConfigTermination_Blocked DEFAULT (300),
        MinimumBlockedSessions     int           NOT NULL CONSTRAINT DF_ConfigTermination_Sessions DEFAULT (1),
        MinimumObservations        int           NOT NULL CONSTRAINT DF_ConfigTermination_Observations DEFAULT (3),
        MinimumStableObservations  int           NOT NULL CONSTRAINT DF_ConfigTermination_Stable DEFAULT (3),
        VerificationDelaySeconds   int           NOT NULL CONSTRAINT DF_ConfigTermination_Verify DEFAULT (20),
        ActionExpirySeconds        int           NOT NULL CONSTRAINT DF_ConfigTermination_Expiry DEFAULT (120),
        MaximumActionsPerCycle     int           NOT NULL CONSTRAINT DF_ConfigTermination_MaxCycle DEFAULT (1),
        MaximumActionsPerHour      int           NOT NULL CONSTRAINT DF_ConfigTermination_MaxHour DEFAULT (3),
        GracefulShutdownSeconds    int           NOT NULL CONSTRAINT DF_ConfigTermination_Grace DEFAULT (10),
        AllowForcedTermination     bit           NOT NULL CONSTRAINT DF_ConfigTermination_Forced DEFAULT (0),
        TerminationLauncherPath    nvarchar(400) NOT NULL,
        TerminationSettingsPath    nvarchar(400) NOT NULL,
        UpdatedUtc                 datetime2(3)  NOT NULL CONSTRAINT DF_ConfigTermination_Updated DEFAULT (SYSUTCDATETIME()),
        UpdatedBy                  sysname       NOT NULL CONSTRAINT DF_ConfigTermination_UpdatedBy DEFAULT (ORIGINAL_LOGIN()),
        RowVersion                 rowversion    NOT NULL,
        CONSTRAINT CK_ConfigTermination_Singleton CHECK (ConfigId = 1),
        CONSTRAINT CK_ConfigTermination_Mode CHECK (OperatingMode IN ('Disabled','AuditOnly','Automatic')),
        CONSTRAINT CK_ConfigTermination_Values CHECK
        (
            MinimumExecutionSeconds BETWEEN 60 AND 86400
            AND MinimumBlockedSeconds BETWEEN 30 AND 86400
            AND MinimumBlockedSessions BETWEEN 1 AND 10000
            AND MinimumObservations BETWEEN 2 AND 100
            AND MinimumStableObservations BETWEEN 2 AND 100
            AND VerificationDelaySeconds BETWEEN 5 AND 3600
            AND ActionExpirySeconds BETWEEN 30 AND 900
            AND MaximumActionsPerCycle BETWEEN 1 AND 10
            AND MaximumActionsPerHour BETWEEN 1 AND 100
            AND GracefulShutdownSeconds BETWEEN 0 AND 300
        )
    );

    INSERT xt.ConfigTermination
        (ConfigId, Enabled, OperatingMode, TerminationLauncherPath, TerminationSettingsPath)
    VALUES
        (1, 0, 'AuditOnly',
         N'C:\ProgramData\SqlXpcmd\Invoke-SafeTermination.ps1',
         N'C:\ProgramData\SqlXpcmd\termination-settings.json');
END;
GO

IF OBJECT_ID(N'xt.BlockingObservation', N'U') IS NULL
BEGIN
    CREATE TABLE xt.BlockingObservation
    (
        ObservationId           bigint          NOT NULL IDENTITY(1,1) CONSTRAINT PK_BlockingObservation PRIMARY KEY,
        CapturedUtc             datetime2(3)    NOT NULL CONSTRAINT DF_BlockingObservation_Captured DEFAULT (SYSUTCDATETIME()),
        WaitingSessionId        smallint        NOT NULL,
        RootBlockingSessionId   smallint        NOT NULL,
        DirectBlockingSessionId smallint        NOT NULL,
        WaitType                nvarchar(120)   NULL,
        WaitDurationMs          bigint          NOT NULL,
        DatabaseId              smallint        NULL,
        ExecutionId             uniqueidentifier NULL,
        RootRequestCpuMs        int             NULL,
        RootRequestReads        bigint          NULL,
        RootRequestWrites       bigint          NULL,
        RootRequestElapsedMs    int             NULL
    );

    CREATE INDEX IX_BlockingObservation_RootTime
        ON xt.BlockingObservation(RootBlockingSessionId, CapturedUtc)
        INCLUDE(ExecutionId, WaitingSessionId, WaitDurationMs);
END;
GO

IF OBJECT_ID(N'xt.TerminationCandidate', N'U') IS NULL
BEGIN
    CREATE TABLE xt.TerminationCandidate
    (
        CandidateId             bigint           NOT NULL IDENTITY(1,1) CONSTRAINT PK_TerminationCandidate PRIMARY KEY,
        ExecutionId             uniqueidentifier NOT NULL,
        RootSessionId           smallint         NOT NULL,
        ProfileId               sysname          NOT NULL,
        ProcessId               int              NOT NULL,
        ProcessCreationTimeUtc  datetime2(3)     NOT NULL,
        State                   varchar(24)      NOT NULL,
        FirstObservedUtc        datetime2(3)     NOT NULL,
        LastObservedUtc         datetime2(3)     NOT NULL,
        ObservationCount        int              NOT NULL,
        StableObservationCount  int              NOT NULL,
        BlockedSessionCount     int              NOT NULL,
        OldestBlockedSeconds    int              NOT NULL,
        LastCpuMs               int              NULL,
        LastReads               bigint           NULL,
        LastWrites              bigint           NULL,
        LastDecisionReason      nvarchar(1024)   NULL,
        RowVersion              rowversion       NOT NULL,
        CONSTRAINT UQ_TerminationCandidate_Execution UNIQUE(ExecutionId),
        CONSTRAINT FK_TerminationCandidate_Execution FOREIGN KEY(ExecutionId) REFERENCES xt.ExecutionRegistry(ExecutionId),
        CONSTRAINT CK_TerminationCandidate_State CHECK (State IN ('Observing','Eligible','Proposed','Actioning','Cleared','Suppressed','Failed'))
    );
END;
GO

IF OBJECT_ID(N'xt.TerminationRuleEvaluation', N'U') IS NULL
BEGIN
    CREATE TABLE xt.TerminationRuleEvaluation
    (
        EvaluationId      bigint          NOT NULL IDENTITY(1,1) CONSTRAINT PK_TerminationRuleEvaluation PRIMARY KEY,
        CandidateId       bigint          NOT NULL,
        EvaluatedUtc      datetime2(3)    NOT NULL CONSTRAINT DF_TerminationRule_Evaluated DEFAULT (SYSUTCDATETIME()),
        RuleCode          varchar(64)     NOT NULL,
        ActualValue       nvarchar(256)   NULL,
        RequiredValue     nvarchar(256)   NULL,
        Passed            bit             NOT NULL,
        Mandatory         bit             NOT NULL CONSTRAINT DF_TerminationRule_Mandatory DEFAULT (1),
        CONSTRAINT FK_TerminationRule_Candidate FOREIGN KEY(CandidateId) REFERENCES xt.TerminationCandidate(CandidateId)
    );
END;
GO

IF OBJECT_ID(N'xt.TerminationAction', N'U') IS NULL
BEGIN
    CREATE TABLE xt.TerminationAction
    (
        ActionId                 uniqueidentifier NOT NULL CONSTRAINT PK_TerminationAction PRIMARY KEY,
        CandidateId              bigint           NOT NULL,
        ExecutionId              uniqueidentifier NOT NULL,
        ProcessId                int              NOT NULL,
        ProcessCreationTimeUtc   datetime2(3)     NOT NULL,
        ExpectedImagePath        nvarchar(1024)   NOT NULL,
        ExpectedOwnerSid         nvarchar(184)    NOT NULL,
        ExpectedCommandHash      binary(32)       NOT NULL,
        ActionTokenHash          binary(32)       NOT NULL,
        Status                   varchar(24)      NOT NULL,
        RequestedUtc             datetime2(3)     NOT NULL,
        ExpiresUtc               datetime2(3)     NOT NULL,
        ClaimedUtc               datetime2(3)     NULL,
        CompletedUtc             datetime2(3)     NULL,
        GracefulAttempted        bit              NULL,
        ForcedAttempted          bit              NULL,
        ResultCode               varchar(64)      NULL,
        ResultMessage            nvarchar(2048)   NULL,
        HelperVersion            varchar(32)      NULL,
        CONSTRAINT FK_TerminationAction_Candidate FOREIGN KEY(CandidateId) REFERENCES xt.TerminationCandidate(CandidateId),
        CONSTRAINT CK_TerminationAction_Status CHECK (Status IN ('Proposed','Dispatched','Claimed','Simulated','GracefulExited','Terminated','AlreadyExited','Rejected','Failed','VerifiedCleared','VerifiedBlocked'))
    );

    CREATE INDEX IX_TerminationAction_StatusTime ON xt.TerminationAction(Status, RequestedUtc);
END;
GO

IF OBJECT_ID(N'xt.TerminationVerification', N'U') IS NULL
BEGIN
    CREATE TABLE xt.TerminationVerification
    (
        VerificationId       bigint           NOT NULL IDENTITY(1,1) CONSTRAINT PK_TerminationVerification PRIMARY KEY,
        ActionId             uniqueidentifier NOT NULL,
        VerifiedUtc          datetime2(3)     NOT NULL CONSTRAINT DF_TerminationVerification_Verified DEFAULT (SYSUTCDATETIME()),
        BlockingCleared      bit              NOT NULL,
        RemainingBlocked     int              NOT NULL,
        Detail               nvarchar(1024)   NULL,
        CONSTRAINT UQ_TerminationVerification_Action UNIQUE(ActionId),
        CONSTRAINT FK_TerminationVerification_Action FOREIGN KEY(ActionId) REFERENCES xt.TerminationAction(ActionId)
    );
END;
GO

CREATE OR ALTER PROCEDURE xt.usp_ClaimTerminationAction
    @ActionId          uniqueidentifier,
    @ActionToken       varbinary(32)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRANSACTION;

    UPDATE xt.TerminationAction WITH (UPDLOCK, HOLDLOCK)
       SET Status = 'Claimed', ClaimedUtc = SYSUTCDATETIME()
     WHERE ActionId = @ActionId
       AND Status = 'Dispatched'
       AND ExpiresUtc > SYSUTCDATETIME()
       AND ActionTokenHash = HASHBYTES('SHA2_256', @ActionToken);

    IF @@ROWCOUNT <> 1
        THROW 51200, 'Termination action cannot be claimed.', 1;

    SELECT
        a.ActionId, a.ExecutionId, a.ProcessId, a.ProcessCreationTimeUtc,
        a.ExpectedImagePath, a.ExpectedOwnerSid, a.ExpectedCommandHash,
        c.GracefulShutdownSeconds, c.AllowForcedTermination,
        c.OperatingMode, c.Enabled
    FROM xt.TerminationAction AS a
    CROSS JOIN xt.ConfigTermination AS c
    WHERE a.ActionId = @ActionId AND c.ConfigId = 1;

    COMMIT TRANSACTION;
END;
GO

CREATE OR ALTER PROCEDURE xt.usp_RecordTerminationResult
    @ActionId            uniqueidentifier,
    @ActionToken         varbinary(32),
    @Status              varchar(24),
    @GracefulAttempted   bit,
    @ForcedAttempted     bit,
    @ResultCode          varchar(64),
    @ResultMessage       nvarchar(2048),
    @HelperVersion       varchar(32)
AS
BEGIN
    SET NOCOUNT ON;

    IF @Status NOT IN ('Simulated','GracefulExited','Terminated','AlreadyExited','Rejected','Failed')
        THROW 51201, 'Invalid termination result status.', 1;

    UPDATE xt.TerminationAction
       SET Status = @Status,
           CompletedUtc = SYSUTCDATETIME(),
           GracefulAttempted = @GracefulAttempted,
           ForcedAttempted = @ForcedAttempted,
           ResultCode = LEFT(@ResultCode, 64),
           ResultMessage = LEFT(@ResultMessage, 2048),
           HelperVersion = LEFT(@HelperVersion, 32)
     WHERE ActionId = @ActionId
       AND Status = 'Claimed'
       AND ActionTokenHash = HASHBYTES('SHA2_256', @ActionToken);

    IF @@ROWCOUNT <> 1
        THROW 51202, 'Termination result was rejected.', 1;
END;
GO

CREATE OR ALTER PROCEDURE xt.usp_MonitorCycle
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @LockResult int;
    EXEC @LockResult = sys.sp_getapplock
        @Resource = N'xt.usp_MonitorCycle', @LockMode = 'Exclusive',
        @LockOwner = 'Session', @LockTimeout = 0;
    IF @LockResult < 0 RETURN;

    DECLARE
        @Now datetime2(3) = SYSUTCDATETIME(),
        @Enabled bit, @Mode varchar(16), @MinExecution int, @MinBlocked int,
        @MinSessions int, @MinObservations int, @MinStable int,
        @VerifyDelay int, @Expiry int, @MaxCycle int, @MaxHour int,
        @TerminationLauncher nvarchar(400), @TerminationSettings nvarchar(400);

    SELECT
        @Enabled = Enabled, @Mode = OperatingMode,
        @MinExecution = MinimumExecutionSeconds,
        @MinBlocked = MinimumBlockedSeconds,
        @MinSessions = MinimumBlockedSessions,
        @MinObservations = MinimumObservations,
        @MinStable = MinimumStableObservations,
        @VerifyDelay = VerificationDelaySeconds,
        @Expiry = ActionExpirySeconds,
        @MaxCycle = MaximumActionsPerCycle,
        @MaxHour = MaximumActionsPerHour,
        @TerminationLauncher = TerminationLauncherPath,
        @TerminationSettings = TerminationSettingsPath
    FROM xt.ConfigTermination WHERE ConfigId = 1;

    IF ISNULL(@Enabled, 0) = 0 OR @Mode = 'Disabled' RETURN;

    CREATE TABLE #Edges
    (
        WaitingSessionId smallint NOT NULL PRIMARY KEY,
        BlockingSessionId smallint NOT NULL,
        WaitType nvarchar(120) NULL,
        WaitDurationMs bigint NOT NULL,
        DatabaseId smallint NULL
    );

    INSERT #Edges(WaitingSessionId, BlockingSessionId, WaitType, WaitDurationMs, DatabaseId)
    SELECT r.session_id, r.blocking_session_id, r.wait_type,
           CONVERT(bigint, r.wait_time), r.database_id
    FROM sys.dm_exec_requests AS r
    WHERE r.blocking_session_id > 0
      AND r.session_id <> r.blocking_session_id;

    ;WITH Chain AS
    (
        SELECT e.WaitingSessionId, e.BlockingSessionId AS CurrentBlocker,
               e.BlockingSessionId AS DirectBlocker, e.WaitType,
               e.WaitDurationMs, e.DatabaseId, 0 AS Depth
        FROM #Edges AS e
        UNION ALL
        SELECT c.WaitingSessionId, e.BlockingSessionId,
               c.DirectBlocker, c.WaitType, c.WaitDurationMs, c.DatabaseId,
               c.Depth + 1
        FROM Chain AS c
        JOIN #Edges AS e ON e.WaitingSessionId = c.CurrentBlocker
        WHERE c.Depth < 31 AND e.BlockingSessionId <> c.WaitingSessionId
    ), Roots AS
    (
        SELECT c.*, ROW_NUMBER() OVER(PARTITION BY c.WaitingSessionId ORDER BY c.Depth DESC) AS rn
        FROM Chain AS c
        WHERE NOT EXISTS (SELECT 1 FROM #Edges AS e WHERE e.WaitingSessionId = c.CurrentBlocker)
    )
    INSERT xt.BlockingObservation
        (CapturedUtc, WaitingSessionId, RootBlockingSessionId, DirectBlockingSessionId,
         WaitType, WaitDurationMs, DatabaseId, ExecutionId,
         RootRequestCpuMs, RootRequestReads, RootRequestWrites, RootRequestElapsedMs)
    SELECT @Now, r.WaitingSessionId, r.CurrentBlocker, r.DirectBlocker,
           r.WaitType, r.WaitDurationMs, r.DatabaseId, er.ExecutionId,
           rr.cpu_time, rr.reads, rr.writes, rr.total_elapsed_time
    FROM Roots AS r
    JOIN xt.ExecutionRegistry AS er
      ON er.SessionId = r.CurrentBlocker AND er.State IN ('Running','TimedOut')
    JOIN xt.ProcessEvidence AS pe ON pe.ExecutionId = er.ExecutionId
    LEFT JOIN sys.dm_exec_requests AS rr ON rr.session_id = r.CurrentBlocker
    WHERE r.rn = 1
    OPTION (MAXRECURSION 32);

    ;WITH CurrentImpact AS
    (
        SELECT bo.ExecutionId, bo.RootBlockingSessionId,
               COUNT(DISTINCT bo.WaitingSessionId) AS BlockedSessions,
               MAX(CONVERT(int, bo.WaitDurationMs / 1000)) AS OldestBlockedSeconds,
               MAX(bo.RootRequestCpuMs) AS CpuMs,
               MAX(bo.RootRequestReads) AS Reads,
               MAX(bo.RootRequestWrites) AS Writes
        FROM xt.BlockingObservation AS bo
        WHERE bo.CapturedUtc = @Now AND bo.ExecutionId IS NOT NULL
        GROUP BY bo.ExecutionId, bo.RootBlockingSessionId
    )
    MERGE xt.TerminationCandidate WITH (HOLDLOCK) AS target
    USING
    (
        SELECT i.*, er.ProfileId, pe.ProcessId, pe.CreationTimeUtc
        FROM CurrentImpact AS i
        JOIN xt.ExecutionRegistry AS er ON er.ExecutionId = i.ExecutionId
        JOIN xt.ProcessEvidence AS pe ON pe.ExecutionId = i.ExecutionId
    ) AS source
    ON target.ExecutionId = source.ExecutionId
    WHEN MATCHED THEN UPDATE SET
        LastObservedUtc = @Now,
        ObservationCount = target.ObservationCount + 1,
        StableObservationCount = CASE
            WHEN ISNULL(target.LastCpuMs, -1) = ISNULL(source.CpuMs, -1)
             AND ISNULL(target.LastReads, -1) = ISNULL(source.Reads, -1)
             AND ISNULL(target.LastWrites, -1) = ISNULL(source.Writes, -1)
            THEN target.StableObservationCount + 1 ELSE 0 END,
        BlockedSessionCount = source.BlockedSessions,
        OldestBlockedSeconds = source.OldestBlockedSeconds,
        LastCpuMs = source.CpuMs, LastReads = source.Reads, LastWrites = source.Writes,
        State = CASE WHEN target.State IN ('Cleared','Failed') THEN 'Observing' ELSE target.State END
    WHEN NOT MATCHED THEN INSERT
        (ExecutionId, RootSessionId, ProfileId, ProcessId, ProcessCreationTimeUtc,
         State, FirstObservedUtc, LastObservedUtc, ObservationCount,
         StableObservationCount, BlockedSessionCount, OldestBlockedSeconds,
         LastCpuMs, LastReads, LastWrites)
    VALUES
        (source.ExecutionId, source.RootBlockingSessionId, source.ProfileId,
         source.ProcessId, source.CreationTimeUtc, 'Observing', @Now, @Now, 1, 0,
         source.BlockedSessions, source.OldestBlockedSeconds,
         source.CpuMs, source.Reads, source.Writes);

    UPDATE c
       SET State = 'Cleared', LastDecisionReason = N'No longer observed as a root blocker.'
    FROM xt.TerminationCandidate AS c
    WHERE c.State IN ('Observing','Eligible','Proposed')
      AND c.LastObservedUtc < @Now
      AND NOT EXISTS
          (SELECT 1 FROM xt.BlockingObservation AS bo
           WHERE bo.CapturedUtc = @Now AND bo.ExecutionId = c.ExecutionId);

    DELETE FROM xt.TerminationRuleEvaluation
    WHERE EvaluatedUtc < DATEADD(day, -90, @Now);

    INSERT xt.TerminationRuleEvaluation(CandidateId, RuleCode, ActualValue, RequiredValue, Passed)
    SELECT c.CandidateId, 'ExecutionAgeSeconds',
           CONVERT(nvarchar(256), DATEDIFF(second, e.RequestedUtc, @Now)),
           CONVERT(nvarchar(256), @MinExecution),
           IIF(DATEDIFF(second, e.RequestedUtc, @Now) >= @MinExecution, 1, 0)
    FROM xt.TerminationCandidate AS c
    JOIN xt.ExecutionRegistry AS e ON e.ExecutionId = c.ExecutionId
    WHERE c.LastObservedUtc = @Now;

    INSERT xt.TerminationRuleEvaluation(CandidateId, RuleCode, ActualValue, RequiredValue, Passed)
    SELECT CandidateId, 'BlockedSeconds', CONVERT(nvarchar(256), OldestBlockedSeconds),
           CONVERT(nvarchar(256), @MinBlocked), IIF(OldestBlockedSeconds >= @MinBlocked, 1, 0)
    FROM xt.TerminationCandidate WHERE LastObservedUtc = @Now;

    INSERT xt.TerminationRuleEvaluation(CandidateId, RuleCode, ActualValue, RequiredValue, Passed)
    SELECT CandidateId, 'BlockedSessions', CONVERT(nvarchar(256), BlockedSessionCount),
           CONVERT(nvarchar(256), @MinSessions), IIF(BlockedSessionCount >= @MinSessions, 1, 0)
    FROM xt.TerminationCandidate WHERE LastObservedUtc = @Now;

    INSERT xt.TerminationRuleEvaluation(CandidateId, RuleCode, ActualValue, RequiredValue, Passed)
    SELECT CandidateId, 'ObservationCount', CONVERT(nvarchar(256), ObservationCount),
           CONVERT(nvarchar(256), @MinObservations), IIF(ObservationCount >= @MinObservations, 1, 0)
    FROM xt.TerminationCandidate WHERE LastObservedUtc = @Now;

    INSERT xt.TerminationRuleEvaluation(CandidateId, RuleCode, ActualValue, RequiredValue, Passed)
    SELECT CandidateId, 'StableObservationCount', CONVERT(nvarchar(256), StableObservationCount),
           CONVERT(nvarchar(256), @MinStable), IIF(StableObservationCount >= @MinStable, 1, 0)
    FROM xt.TerminationCandidate WHERE LastObservedUtc = @Now;

    UPDATE c
       SET State = CASE WHEN failed.CandidateId IS NULL THEN 'Eligible' ELSE 'Observing' END,
           LastDecisionReason = CASE WHEN failed.CandidateId IS NULL
                THEN N'All mandatory rules passed.' ELSE N'One or more mandatory rules have not passed.' END
    FROM xt.TerminationCandidate AS c
    OUTER APPLY
    (
        SELECT TOP (1) r.CandidateId
        FROM xt.TerminationRuleEvaluation AS r
        WHERE r.CandidateId = c.CandidateId AND r.EvaluatedUtc >= @Now AND r.Passed = 0 AND r.Mandatory = 1
    ) AS failed
    WHERE c.LastObservedUtc = @Now AND c.State IN ('Observing','Eligible');

    DECLARE @ActionsThisCycle int = 0;
    WHILE @ActionsThisCycle < @MaxCycle
      AND (SELECT COUNT(*) FROM xt.TerminationAction WHERE RequestedUtc >= DATEADD(hour, -1, @Now)
           AND Status NOT IN ('Proposed','Rejected')) < @MaxHour
    BEGIN
        DECLARE @CandidateId bigint, @ExecutionId uniqueidentifier, @Pid int,
                @Creation datetime2(3), @Image nvarchar(1024), @Owner nvarchar(184),
                @CommandHash binary(32);

        SELECT TOP (1)
            @CandidateId = c.CandidateId, @ExecutionId = c.ExecutionId,
            @Pid = pe.ProcessId, @Creation = pe.CreationTimeUtc,
            @Image = pe.ImagePath, @Owner = pe.OwnerSid, @CommandHash = pe.CommandHash
        FROM xt.TerminationCandidate AS c WITH (UPDLOCK, READPAST)
        JOIN xt.ProcessEvidence AS pe ON pe.ExecutionId = c.ExecutionId
        WHERE c.State = 'Eligible'
          AND NOT EXISTS
              (SELECT 1 FROM xt.TerminationAction AS a
               WHERE a.CandidateId = c.CandidateId
                 AND a.Status IN ('Proposed','Dispatched','Claimed'))
        ORDER BY c.OldestBlockedSeconds DESC, c.CandidateId;

        IF @CandidateId IS NULL BREAK;

        DECLARE @ActionId uniqueidentifier = NEWID(),
                @ActionToken varbinary(32) = CRYPT_GEN_RANDOM(32),
                @ActionStatus varchar(24) = IIF(@Mode = 'Automatic', 'Dispatched', 'Proposed');

        INSERT xt.TerminationAction
            (ActionId, CandidateId, ExecutionId, ProcessId, ProcessCreationTimeUtc,
             ExpectedImagePath, ExpectedOwnerSid, ExpectedCommandHash,
             ActionTokenHash, Status, RequestedUtc, ExpiresUtc)
        VALUES
            (@ActionId, @CandidateId, @ExecutionId, @Pid, @Creation,
             @Image, @Owner, @CommandHash, HASHBYTES('SHA2_256', @ActionToken),
             @ActionStatus, @Now, DATEADD(second, @Expiry, @Now));

        UPDATE xt.TerminationCandidate
           SET State = IIF(@Mode = 'Automatic', 'Actioning', 'Proposed'),
               LastDecisionReason = IIF(@Mode = 'Automatic', N'Termination action dispatched.', N'Audit-only action proposed.')
         WHERE CandidateId = @CandidateId;

        IF @Mode = 'Automatic'
        BEGIN
            IF @TerminationLauncher LIKE N'% %' OR @TerminationSettings LIKE N'% %'
               OR @TerminationLauncher LIKE N'%[&|<>^"' + CHAR(13) + CHAR(10) + N']%'
               OR @TerminationSettings LIKE N'%[&|<>^"' + CHAR(13) + CHAR(10) + N']%'
            BEGIN
                UPDATE xt.TerminationAction SET Status = 'Rejected', CompletedUtc = SYSUTCDATETIME(),
                    ResultCode = 'UnsafePath', ResultMessage = N'Termination paths are unsafe for xp_cmdshell.'
                WHERE ActionId = @ActionId;
                UPDATE xt.TerminationCandidate SET State = 'Failed' WHERE CandidateId = @CandidateId;
            END
            ELSE
            BEGIN
                DECLARE @ServerBytes varbinary(max) = CONVERT(varbinary(max), CONVERT(nvarchar(256), SERVERPROPERTY('ServerName'))),
                        @DatabaseBytes varbinary(max) = CONVERT(varbinary(max), CONVERT(nvarchar(256), DB_NAME())),
                        @ServerB64 varchar(max), @DatabaseB64 varchar(max), @TokenB64 varchar(64),
                        @Invocation varchar(8000), @ReturnCode int;

                SELECT
                    @ServerB64 = CAST(N'' AS xml).value('xs:base64Binary(sql:variable("@ServerBytes"))', 'varchar(max)'),
                    @DatabaseB64 = CAST(N'' AS xml).value('xs:base64Binary(sql:variable("@DatabaseBytes"))', 'varchar(max)'),
                    @TokenB64 = CAST(N'' AS xml).value('xs:base64Binary(sql:variable("@ActionToken"))', 'varchar(64)');

                SET @Invocation = CONVERT(varchar(8000),
                    N'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy AllSigned -File ' + @TerminationLauncher +
                    N' -ActionId ' + CONVERT(nvarchar(36), @ActionId) +
                    N' -ServerB64 ' + @ServerB64 + N' -DatabaseB64 ' + @DatabaseB64 +
                    N' -ActionTokenB64 ' + @TokenB64 + N' -SettingsPath ' + @TerminationSettings);

                BEGIN TRY
                    EXEC @ReturnCode = master.dbo.xp_cmdshell @Invocation;
                    IF @ReturnCode <> 0 AND EXISTS
                       (SELECT 1 FROM xt.TerminationAction WHERE ActionId = @ActionId AND Status IN ('Dispatched','Claimed'))
                        UPDATE xt.TerminationAction SET Status = 'Failed', CompletedUtc = SYSUTCDATETIME(),
                            ResultCode = 'HelperExit', ResultMessage = N'Termination helper returned a non-zero status.'
                        WHERE ActionId = @ActionId;
                END TRY
                BEGIN CATCH
                    UPDATE xt.TerminationAction SET Status = 'Failed', CompletedUtc = SYSUTCDATETIME(),
                        ResultCode = 'HelperLaunch', ResultMessage = LEFT(ERROR_MESSAGE(), 2048)
                    WHERE ActionId = @ActionId AND Status IN ('Dispatched','Claimed');
                END CATCH;
            END;
        END;

        SET @ActionsThisCycle += 1;
        SELECT @CandidateId = NULL, @ExecutionId = NULL;
    END;

    INSERT xt.TerminationVerification(ActionId, BlockingCleared, RemainingBlocked, Detail)
    SELECT a.ActionId,
           IIF(remaining.RemainingBlocked = 0, 1, 0),
           remaining.RemainingBlocked,
           IIF(remaining.RemainingBlocked = 0, N'No requests are currently blocked by the registered root SPID.',
               N'One or more requests remain directly blocked by the registered root SPID.')
    FROM xt.TerminationAction AS a
    JOIN xt.TerminationCandidate AS c ON c.CandidateId = a.CandidateId
    CROSS APPLY
    (
        SELECT COUNT(*) AS RemainingBlocked
        FROM sys.dm_exec_requests AS r
        WHERE r.blocking_session_id = c.RootSessionId
    ) AS remaining
    WHERE a.Status IN ('GracefulExited','Terminated','AlreadyExited')
      AND a.CompletedUtc <= DATEADD(second, -@VerifyDelay, @Now)
      AND NOT EXISTS (SELECT 1 FROM xt.TerminationVerification AS v WHERE v.ActionId = a.ActionId);

    UPDATE a
       SET Status = IIF(v.BlockingCleared = 1, 'VerifiedCleared', 'VerifiedBlocked')
    FROM xt.TerminationAction AS a
    JOIN xt.TerminationVerification AS v ON v.ActionId = a.ActionId
    WHERE a.Status IN ('GracefulExited','Terminated','AlreadyExited');

    UPDATE c
       SET State = IIF(v.BlockingCleared = 1, 'Cleared', 'Failed'),
           LastDecisionReason = v.Detail
    FROM xt.TerminationCandidate AS c
    JOIN xt.TerminationAction AS a ON a.CandidateId = c.CandidateId
    JOIN xt.TerminationVerification AS v ON v.ActionId = a.ActionId
    WHERE a.Status IN ('VerifiedCleared','VerifiedBlocked');

    UPDATE c
       SET State = 'Suppressed', LastDecisionReason = N'Windows helper completed a simulation; no process was terminated.'
    FROM xt.TerminationCandidate AS c
    JOIN xt.TerminationAction AS a ON a.CandidateId = c.CandidateId
    WHERE c.State = 'Actioning' AND a.Status = 'Simulated';

    UPDATE a
       SET Status = 'Failed', CompletedUtc = @Now,
           ResultCode = 'Expired', ResultMessage = N'Termination action expired before completion.'
    FROM xt.TerminationAction AS a
    WHERE a.Status IN ('Dispatched','Claimed') AND a.ExpiresUtc <= @Now;

    UPDATE c
       SET State = 'Failed', LastDecisionReason = COALESCE(a.ResultMessage, N'Termination action failed or was rejected.')
    FROM xt.TerminationCandidate AS c
    JOIN xt.TerminationAction AS a ON a.CandidateId = c.CandidateId
    WHERE c.State = 'Actioning' AND a.Status IN ('Rejected','Failed');
END;
GO

CREATE OR ALTER VIEW xt.vw_TerminationDashboard
AS
SELECT
    c.CandidateId, c.ExecutionId, c.RootSessionId, c.ProfileId,
    c.ProcessId, c.ProcessCreationTimeUtc, c.State AS CandidateState,
    c.FirstObservedUtc, c.LastObservedUtc, c.ObservationCount,
    c.StableObservationCount, c.BlockedSessionCount, c.OldestBlockedSeconds,
    c.LastDecisionReason,
    a.ActionId, a.Status AS ActionStatus, a.RequestedUtc, a.CompletedUtc,
    a.ResultCode, a.ResultMessage,
    v.BlockingCleared, v.RemainingBlocked, v.VerifiedUtc
FROM xt.TerminationCandidate AS c
LEFT JOIN xt.TerminationAction AS a ON a.CandidateId = c.CandidateId
LEFT JOIN xt.TerminationVerification AS v ON v.ActionId = a.ActionId;
GO

GRANT SELECT ON xt.vw_TerminationDashboard TO xt_command_executor;
GO
