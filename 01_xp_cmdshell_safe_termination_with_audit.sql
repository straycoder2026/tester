/*
 Safe xp_cmdshell Long-Running Process Detection
 Revised version with append-only audit history.
*/

SET NOCOUNT ON;
GO

/*==============================================================
  1. CONFIGURATION
==============================================================*/
IF OBJECT_ID('dbo.XpCmdShellTerminationConfig','U') IS NULL
BEGIN
    CREATE TABLE dbo.XpCmdShellTerminationConfig
    (
        ConfigId                         int IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_XpCmdShellTerminationConfig PRIMARY KEY,
        Enabled                          bit NOT NULL DEFAULT (0),
        MinimumRuntimeMinutes            int NOT NULL DEFAULT (240),
        RequireOpenTransaction           bit NOT NULL DEFAULT (1),
        RequireBlocking                  bit NOT NULL DEFAULT (1),
        MaxTerminationsPerCycle          int NOT NULL DEFAULT (5),
        ProcessStartToleranceMinutes     int NOT NULL DEFAULT (5),
        DryRun                           bit NOT NULL DEFAULT (1),
        CreatedDate                      datetime2(0) NOT NULL DEFAULT (SYSDATETIME()),
        ModifiedDate                     datetime2(0) NULL
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.XpCmdShellTerminationConfig)
BEGIN
    INSERT dbo.XpCmdShellTerminationConfig
    (
        Enabled,
        MinimumRuntimeMinutes,
        RequireOpenTransaction,
        RequireBlocking,
        MaxTerminationsPerCycle,
        ProcessStartToleranceMinutes,
        DryRun
    )
    VALUES (0,240,1,1,5,5,1);
END;
GO

/*==============================================================
  2. TERMINATION RULES
==============================================================*/
IF OBJECT_ID('dbo.XpCmdShellTerminationRule','U') IS NULL
BEGIN
    CREATE TABLE dbo.XpCmdShellTerminationRule
    (
        RuleId                   int IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_XpCmdShellTerminationRule PRIMARY KEY,
        RuleName                 varchar(100) NOT NULL,
        Enabled                  bit NOT NULL DEFAULT (0),
        ProcessName              nvarchar(128) NOT NULL,
        CommandLineContains      nvarchar(1000) NOT NULL,
        Notes                    nvarchar(2000) NULL,
        CreatedDate              datetime2(0) NOT NULL DEFAULT (SYSDATETIME()),
        ModifiedDate             datetime2(0) NULL
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.XpCmdShellTerminationRule WHERE RuleName='LAB-PING')
BEGIN
    INSERT dbo.XpCmdShellTerminationRule
    (RuleName,Enabled,ProcessName,CommandLineContains,Notes)
    VALUES
    ('LAB-PING',0,'ping.exe','127.0.0.1',
     'LAB ONLY. Use with EXEC xp_cmdshell ''ping 127.0.0.1 -t'';');
END;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.XpCmdShellTerminationRule WHERE RuleName='PROD-BCP')
BEGIN
    INSERT dbo.XpCmdShellTerminationRule
    (RuleName,Enabled,ProcessName,CommandLineContains,Notes)
    VALUES
    ('PROD-BCP',0,'bcp.exe','REPLACE_WITH_APPROVED_BCP_COMMAND_SIGNATURE',
     'Enable only after confirming an unambiguous BCP command-line signature.');
END;
GO

/*==============================================================
  3. CANDIDATE / CURRENT STATE
==============================================================*/
IF OBJECT_ID('dbo.XpCmdShellTerminationCandidate','U') IS NULL
BEGIN
    CREATE TABLE dbo.XpCmdShellTerminationCandidate
    (
        CandidateId               bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_XpCmdShellTerminationCandidate PRIMARY KEY,

        SessionId                 int NOT NULL,
        RequestId                 int NULL,
        DetectedAt                datetime2(0) NOT NULL,
        StartTime                 datetime2(0) NULL,
        RuntimeMinutes            int NULL,

        DatabaseName              sysname NULL,
        LoginName                 sysname NULL,
        HostName                  nvarchar(128) NULL,
        ProgramName               nvarchar(256) NULL,

        SqlStatus                 nvarchar(60) NULL,
        SqlCommand                nvarchar(60) NULL,
        WaitType                  nvarchar(120) NULL,
        WaitTimeMs                bigint NULL,
        WaitResource              nvarchar(256) NULL,

        OpenTransactionCount      int NULL,
        BlockedSessionCount       int NULL,
        CommandText               nvarchar(max) NULL,

        ProcessId                 int NULL,
        ParentProcessId           int NULL,
        ProcessName               nvarchar(128) NULL,
        ProcessStartTime          datetime2(0) NULL,
        WindowsAccount            nvarchar(256) NULL,
        ProcessCommandLine        nvarchar(max) NULL,

        Status                    varchar(50) NOT NULL,
        ValidationMessage         nvarchar(2000) NULL,
        TerminatedAt              datetime2(0) NULL,
        ResultMessage             nvarchar(2000) NULL
    );

    CREATE INDEX IX_XpCmdShellTerminationCandidate_Status
        ON dbo.XpCmdShellTerminationCandidate(Status,CandidateId);

    CREATE INDEX IX_XpCmdShellTerminationCandidate_Session
        ON dbo.XpCmdShellTerminationCandidate(SessionId,StartTime);
END;
GO

/*==============================================================
  4. APPEND-ONLY AUDIT HISTORY
==============================================================*/
IF OBJECT_ID('dbo.XpCmdShellTerminationAudit','U') IS NULL
BEGIN
    CREATE TABLE dbo.XpCmdShellTerminationAudit
    (
        AuditId                    bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_XpCmdShellTerminationAudit PRIMARY KEY,
        CandidateId                bigint NULL,
        EventTime                  datetime2(0) NOT NULL
            CONSTRAINT DF_XpCmdShellTerminationAudit_EventTime DEFAULT (SYSDATETIME()),
        EventType                  varchar(100) NOT NULL,
        SessionId                  int NULL,
        ProcessId                  int NULL,
        ParentProcessId            int NULL,
        ProcessName                nvarchar(128) NULL,
        WindowsAccount             nvarchar(256) NULL,
        RuntimeMinutes             int NULL,
        WaitType                   nvarchar(120) NULL,
        OpenTransactionCount       int NULL,
        BlockedSessionCount        int NULL,
        RuleName                   varchar(100) NULL,
        PerformedBy                nvarchar(256) NULL,
        Message                    nvarchar(4000) NULL,
        DetailsJson                nvarchar(max) NULL
    );

    CREATE INDEX IX_XpCmdShellTerminationAudit_Candidate
        ON dbo.XpCmdShellTerminationAudit(CandidateId, AuditId);

    CREATE INDEX IX_XpCmdShellTerminationAudit_EventTime
        ON dbo.XpCmdShellTerminationAudit(EventTime);
END;
GO

/*==============================================================
  5. AUDIT WRITE PROCEDURE
==============================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_WriteXpCmdShellTerminationAudit
(
      @CandidateId              bigint = NULL
    , @EventType                varchar(100)
    , @SessionId                int = NULL
    , @ProcessId                int = NULL
    , @ParentProcessId          int = NULL
    , @ProcessName              nvarchar(128) = NULL
    , @WindowsAccount           nvarchar(256) = NULL
    , @RuntimeMinutes           int = NULL
    , @WaitType                 nvarchar(120) = NULL
    , @OpenTransactionCount     int = NULL
    , @BlockedSessionCount      int = NULL
    , @RuleName                 varchar(100) = NULL
    , @PerformedBy              nvarchar(256) = NULL
    , @Message                  nvarchar(4000) = NULL
    , @DetailsJson              nvarchar(max) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    INSERT dbo.XpCmdShellTerminationAudit
    (
        CandidateId, EventType, SessionId, ProcessId, ParentProcessId,
        ProcessName, WindowsAccount, RuntimeMinutes, WaitType,
        OpenTransactionCount, BlockedSessionCount, RuleName,
        PerformedBy, Message, DetailsJson
    )
    VALUES
    (
        @CandidateId, @EventType, @SessionId, @ProcessId, @ParentProcessId,
        @ProcessName, @WindowsAccount, @RuntimeMinutes, @WaitType,
        @OpenTransactionCount, @BlockedSessionCount, @RuleName,
        @PerformedBy, @Message, @DetailsJson
    );
END;
GO

/*==============================================================
  6. DETECTION PROCEDURE
==============================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_DetectLongRunningXpCmdShell
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
          @Enabled                 bit
        , @MinimumRuntimeMinutes   int
        , @RequireOpenTransaction  bit
        , @RequireBlocking         bit
        , @DetectedAt              datetime2(0) = SYSDATETIME();

    SELECT TOP (1)
          @Enabled                 = Enabled
        , @MinimumRuntimeMinutes   = MinimumRuntimeMinutes
        , @RequireOpenTransaction  = RequireOpenTransaction
        , @RequireBlocking         = RequireBlocking
    FROM dbo.XpCmdShellTerminationConfig
    ORDER BY ConfigId DESC;

    IF ISNULL(@Enabled,0)=0 RETURN;
    IF @MinimumRuntimeMinutes IS NULL OR @MinimumRuntimeMinutes < 0 RETURN;

    DECLARE @Inserted TABLE
    (
        CandidateId bigint,
        SessionId int,
        RuntimeMinutes int,
        WaitType nvarchar(120),
        OpenTransactionCount int,
        BlockedSessionCount int
    );

    ;WITH ActiveRequests AS
    (
        SELECT
              r.session_id
            , r.request_id
            , r.start_time
            , r.status
            , r.command
            , r.wait_type
            , CONVERT(bigint,r.wait_time) AS wait_time
            , r.wait_resource
            , s.login_name
            , s.host_name
            , s.program_name
            , s.open_transaction_count
            , DB_NAME(r.database_id) AS DatabaseName
            , DATEDIFF(MINUTE,r.start_time,@DetectedAt) AS RuntimeMinutes
            , txt.text AS SqlText
        FROM sys.dm_exec_requests r
        JOIN sys.dm_exec_sessions s
          ON s.session_id=r.session_id
        OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) txt
        WHERE r.session_id<>@@SPID
          AND s.is_user_process=1
    ),
    BlockingInfo AS
    (
        SELECT blocking_session_id AS SessionId,
               COUNT(*) AS BlockedSessionCount
        FROM sys.dm_exec_requests
        WHERE blocking_session_id>0
        GROUP BY blocking_session_id
    ),
    CandidateRequests AS
    (
        SELECT
              ar.session_id, ar.request_id, ar.start_time, ar.RuntimeMinutes,
              ar.DatabaseName, ar.login_name, ar.host_name, ar.program_name,
              ar.status, ar.command, ar.wait_type, ar.wait_time, ar.wait_resource,
              ar.open_transaction_count,
              ISNULL(bi.BlockedSessionCount,0) AS BlockedSessionCount,
              ar.SqlText
        FROM ActiveRequests ar
        LEFT JOIN BlockingInfo bi
          ON bi.SessionId=ar.session_id
        WHERE ar.RuntimeMinutes>=@MinimumRuntimeMinutes
          AND
          (
             ar.SqlText LIKE '%xp_cmdshell%'
             OR ar.wait_type='PREEMPTIVE_OS_PIPEOPS'
          )
          AND
          (
             @RequireOpenTransaction=0
             OR ar.open_transaction_count>0
          )
          AND
          (
             @RequireBlocking=0
             OR ISNULL(bi.BlockedSessionCount,0)>0
          )
    )
    INSERT dbo.XpCmdShellTerminationCandidate
    (
        SessionId,RequestId,DetectedAt,StartTime,RuntimeMinutes,
        DatabaseName,LoginName,HostName,ProgramName,
        SqlStatus,SqlCommand,WaitType,WaitTimeMs,WaitResource,
        OpenTransactionCount,BlockedSessionCount,CommandText,Status
    )
    OUTPUT
        inserted.CandidateId,
        inserted.SessionId,
        inserted.RuntimeMinutes,
        inserted.WaitType,
        inserted.OpenTransactionCount,
        inserted.BlockedSessionCount
    INTO @Inserted
    SELECT
        c.session_id,c.request_id,@DetectedAt,c.start_time,c.RuntimeMinutes,
        c.DatabaseName,c.login_name,c.host_name,c.program_name,
        c.status,c.command,c.wait_type,c.wait_time,c.wait_resource,
        c.open_transaction_count,c.BlockedSessionCount,c.SqlText,
        'PendingValidation'
    FROM CandidateRequests c
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM dbo.XpCmdShellTerminationCandidate x
        WHERE x.SessionId=c.session_id
          AND ISNULL(x.StartTime,'19000101')=ISNULL(c.start_time,'19000101')
          AND x.Status IN ('PendingValidation','Validated','TerminationRequested')
    );

    INSERT dbo.XpCmdShellTerminationAudit
    (
        CandidateId, EventType, SessionId, RuntimeMinutes, WaitType,
        OpenTransactionCount, BlockedSessionCount, PerformedBy, Message
    )
    SELECT
        CandidateId,
        'CandidateDetected',
        SessionId,
        RuntimeMinutes,
        WaitType,
        OpenTransactionCount,
        BlockedSessionCount,
        SUSER_SNAME(),
        'Long-running xp_cmdshell candidate inserted with PendingValidation status.'
    FROM @Inserted;
END;
GO

/*==============================================================
  7. STATUS / AUDIT VIEWS
==============================================================*/
CREATE OR ALTER VIEW dbo.vw_XpCmdShellTerminationStatus
AS
SELECT
      CandidateId,SessionId,DetectedAt,StartTime,RuntimeMinutes,WaitType,
      OpenTransactionCount,BlockedSessionCount,ProcessId,ParentProcessId,
      ProcessName,Status,TerminatedAt,ValidationMessage,ResultMessage
FROM dbo.XpCmdShellTerminationCandidate;
GO

CREATE OR ALTER VIEW dbo.vw_XpCmdShellTerminationAudit
AS
SELECT
      AuditId,CandidateId,EventTime,EventType,SessionId,ProcessId,
      ParentProcessId,ProcessName,WindowsAccount,RuntimeMinutes,WaitType,
      OpenTransactionCount,BlockedSessionCount,RuleName,PerformedBy,
      Message,DetailsJson
FROM dbo.XpCmdShellTerminationAudit;
GO

/*==============================================================
  8. SQL SERVER AGENT JOB
==============================================================*/
DECLARE @JobName sysname = N'Safe xp_cmdshell Process Monitor';
DECLARE @DatabaseName sysname = DB_NAME();
DECLARE @PowerShellPath nvarchar(4000) =
    N'C:\SqlProcessMonitor\TerminateHungXpCmdShell.ps1';
DECLARE @ServerName nvarchar(256) =
    CONVERT(nvarchar(256),SERVERPROPERTY('ServerName'));
DECLARE @CmdExecCommand nvarchar(max);

SET @CmdExecCommand =
    N'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' +
    @PowerShellPath +
    N'" -SqlServer "' + REPLACE(@ServerName,'"','""') +
    N'" -Database "' + REPLACE(@DatabaseName,'"','""') + N'"';

IF NOT EXISTS
(
    SELECT 1 FROM msdb.dbo.sysjobs WHERE name=@JobName
)
BEGIN
    EXEC msdb.dbo.sp_add_job
         @job_name=@JobName,
         @enabled=1,
         @description=N'Detects and safely validates/terminates long-running xp_cmdshell processes with append-only audit history.';

    EXEC msdb.dbo.sp_add_jobstep
         @job_name=@JobName,
         @step_name=N'1 - Detect long-running xp_cmdshell',
         @subsystem=N'TSQL',
         @database_name=@DatabaseName,
         @command=N'EXEC dbo.usp_DetectLongRunningXpCmdShell;',
         @on_success_action=3,
         @on_fail_action=2;

    EXEC msdb.dbo.sp_add_jobstep
         @job_name=@JobName,
         @step_name=N'2 - Validate and terminate Windows process',
         @subsystem=N'CmdExec',
         @command=@CmdExecCommand,
         @on_success_action=1,
         @on_fail_action=2;

    EXEC msdb.dbo.sp_add_jobschedule
         @job_name=@JobName,
         @name=N'Every 2 minutes',
         @enabled=1,
         @freq_type=4,
         @freq_interval=1,
         @freq_subday_type=4,
         @freq_subday_interval=2,
         @active_start_time=0;

    EXEC msdb.dbo.sp_add_jobserver
         @job_name=@JobName;
END;
GO
