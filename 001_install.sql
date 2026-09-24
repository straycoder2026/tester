/*
  Registered xp_cmdshell wrapper
  Run in the designated DBA/monitor database.
  Review all security grants for the target environment before deployment.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF SCHEMA_ID(N'xt') IS NULL EXEC(N'CREATE SCHEMA xt AUTHORIZATION dbo;');
GO

IF OBJECT_ID(N'xt.ConfigInstance', N'U') IS NULL
BEGIN
    CREATE TABLE xt.ConfigInstance
    (
        ConfigId             tinyint          NOT NULL CONSTRAINT PK_ConfigInstance PRIMARY KEY,
        Enabled              bit              NOT NULL CONSTRAINT DF_ConfigInstance_Enabled DEFAULT (0),
        LauncherPath         nvarchar(400)    NOT NULL,
        ProfilePath          nvarchar(400)    NOT NULL,
        MaxPayloadCharacters int              NOT NULL CONSTRAINT DF_ConfigInstance_MaxPayload DEFAULT (3500),
        UpdatedUtc           datetime2(3)     NOT NULL CONSTRAINT DF_ConfigInstance_Updated DEFAULT (SYSUTCDATETIME()),
        UpdatedBy            sysname          NOT NULL CONSTRAINT DF_ConfigInstance_UpdatedBy DEFAULT (ORIGINAL_LOGIN()),
        RowVersion           rowversion       NOT NULL,
        CONSTRAINT CK_ConfigInstance_Singleton CHECK (ConfigId = 1),
        CONSTRAINT CK_ConfigInstance_MaxPayload CHECK (MaxPayloadCharacters BETWEEN 256 AND 3500)
    );

    INSERT xt.ConfigInstance(ConfigId, Enabled, LauncherPath, ProfilePath)
    VALUES (1, 0, N'C:\ProgramData\SqlXpcmd\Invoke-RegisteredCommand.ps1',
                   N'C:\ProgramData\SqlXpcmd\command-profiles.json');
END;
GO

IF OBJECT_ID(N'xt.CommandProfile', N'U') IS NULL
BEGIN
    CREATE TABLE xt.CommandProfile
    (
        ProfileId            sysname          NOT NULL CONSTRAINT PK_CommandProfile PRIMARY KEY,
        Enabled              bit              NOT NULL CONSTRAINT DF_CommandProfile_Enabled DEFAULT (0),
        Description          nvarchar(400)    NOT NULL,
        OwnerName            nvarchar(256)    NOT NULL,
        PolicyId             int              NULL,
        UpdatedUtc           datetime2(3)     NOT NULL CONSTRAINT DF_CommandProfile_Updated DEFAULT (SYSUTCDATETIME()),
        UpdatedBy            sysname          NOT NULL CONSTRAINT DF_CommandProfile_UpdatedBy DEFAULT (ORIGINAL_LOGIN()),
        CONSTRAINT CK_CommandProfile_Id CHECK (ProfileId NOT LIKE N'%[^A-Za-z0-9_.-]%')
    );
END;
GO

IF OBJECT_ID(N'xt.ExecutionRegistry', N'U') IS NULL
BEGIN
    CREATE TABLE xt.ExecutionRegistry
    (
        ExecutionId          uniqueidentifier NOT NULL CONSTRAINT PK_ExecutionRegistry PRIMARY KEY,
        InstanceName         sysname          NOT NULL,
        DatabaseName         sysname          NOT NULL,
        SessionId            smallint         NOT NULL,
        RequestId            int              NULL,
        ProfileId            sysname          NOT NULL,
        ArgumentsHash        binary(32)       NOT NULL,
        RegistrationHash     binary(32)       NOT NULL,
        RequestedUtc         datetime2(3)     NOT NULL,
        StartedUtc           datetime2(3)     NULL,
        LastHeartbeatUtc     datetime2(3)     NULL,
        CompletedUtc         datetime2(3)     NULL,
        State                varchar(24)      NOT NULL,
        ProcessId            int              NULL,
        ExitCode             int              NULL,
        ErrorNumber          int              NULL,
        ErrorMessage         nvarchar(2048)   NULL,
        CallerLogin          sysname          NOT NULL,
        CallerHost           nvarchar(128)    NULL,
        CallerProgram        nvarchar(128)    NULL,
        CorrelationVersion   tinyint          NOT NULL CONSTRAINT DF_ExecutionRegistry_CorrelationVersion DEFAULT (1),
        RowVersion           rowversion       NOT NULL,
        CONSTRAINT FK_ExecutionRegistry_Profile FOREIGN KEY(ProfileId) REFERENCES xt.CommandProfile(ProfileId),
        CONSTRAINT CK_ExecutionRegistry_State CHECK (State IN ('Pending','Running','Succeeded','Failed','TimedOut','LaunchRejected'))
    );

    CREATE INDEX IX_ExecutionRegistry_StateHeartbeat
        ON xt.ExecutionRegistry(State, LastHeartbeatUtc)
        INCLUDE(SessionId, ProfileId, ProcessId, StartedUtc);
END;
GO

IF OBJECT_ID(N'xt.ProcessEvidence', N'U') IS NULL
BEGIN
    CREATE TABLE xt.ProcessEvidence
    (
        EvidenceId           bigint           NOT NULL IDENTITY(1,1) CONSTRAINT PK_ProcessEvidence PRIMARY KEY,
        ExecutionId          uniqueidentifier NOT NULL,
        ProcessId            int              NOT NULL,
        ParentProcessId      int              NOT NULL,
        CreationTimeUtc      datetime2(3)     NOT NULL,
        ImagePath            nvarchar(1024)   NOT NULL,
        OwnerSid             nvarchar(184)    NOT NULL,
        CommandHash          binary(32)       NOT NULL,
        CapturedUtc          datetime2(3)     NOT NULL CONSTRAINT DF_ProcessEvidence_Captured DEFAULT (SYSUTCDATETIME()),
        LauncherVersion      varchar(32)      NOT NULL,
        CONSTRAINT FK_ProcessEvidence_Execution FOREIGN KEY(ExecutionId) REFERENCES xt.ExecutionRegistry(ExecutionId),
        CONSTRAINT UQ_ProcessEvidence_Execution UNIQUE(ExecutionId),
        CONSTRAINT UQ_ProcessEvidence_ProcessIdentity UNIQUE(ProcessId, CreationTimeUtc)
    );
END;
GO

CREATE OR ALTER PROCEDURE xt.usp_RegisterProcess
    @ExecutionId       uniqueidentifier,
    @RegistrationToken varbinary(32),
    @ProcessId         int,
    @ParentProcessId   int,
    @CreationTimeUtc   datetime2(3),
    @ImagePath         nvarchar(1024),
    @OwnerSid          nvarchar(184),
    @CommandHash       binary(32),
    @LauncherVersion   varchar(32)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @ProcessId <= 0 OR @ParentProcessId < 0 OR @CreationTimeUtc IS NULL
        THROW 51020, 'Invalid process identity.', 1;

    BEGIN TRANSACTION;

    UPDATE xt.ExecutionRegistry WITH (UPDLOCK, HOLDLOCK)
       SET State = 'Running',
           StartedUtc = COALESCE(StartedUtc, SYSUTCDATETIME()),
           LastHeartbeatUtc = SYSUTCDATETIME(),
           ProcessId = @ProcessId
     WHERE ExecutionId = @ExecutionId
       AND State = 'Pending'
       AND RegistrationHash = HASHBYTES('SHA2_256', @RegistrationToken);

    IF @@ROWCOUNT <> 1
        THROW 51021, 'Execution token is invalid, expired, or already registered.', 1;

    INSERT xt.ProcessEvidence
        (ExecutionId, ProcessId, ParentProcessId, CreationTimeUtc, ImagePath,
         OwnerSid, CommandHash, LauncherVersion)
    VALUES
        (@ExecutionId, @ProcessId, @ParentProcessId, @CreationTimeUtc, @ImagePath,
         @OwnerSid, @CommandHash, @LauncherVersion);

    COMMIT TRANSACTION;
END;
GO

CREATE OR ALTER PROCEDURE xt.usp_HeartbeatExecution
    @ExecutionId       uniqueidentifier,
    @RegistrationToken varbinary(32),
    @ProcessId         int
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE xt.ExecutionRegistry
       SET LastHeartbeatUtc = SYSUTCDATETIME()
     WHERE ExecutionId = @ExecutionId
       AND ProcessId = @ProcessId
       AND State = 'Running'
       AND RegistrationHash = HASHBYTES('SHA2_256', @RegistrationToken);

    IF @@ROWCOUNT <> 1
        THROW 51022, 'Heartbeat rejected.', 1;
END;
GO

CREATE OR ALTER PROCEDURE xt.usp_CompleteExecution
    @ExecutionId       uniqueidentifier,
    @RegistrationToken varbinary(32),
    @ProcessId         int = NULL,
    @State             varchar(24),
    @ExitCode          int = NULL,
    @ErrorNumber       int = NULL,
    @ErrorMessage      nvarchar(2048) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @State NOT IN ('Succeeded','Failed','TimedOut','LaunchRejected')
        THROW 51023, 'Invalid terminal state.', 1;

    UPDATE xt.ExecutionRegistry
       SET State = @State,
           ProcessId = COALESCE(ProcessId, @ProcessId),
           LastHeartbeatUtc = SYSUTCDATETIME(),
           CompletedUtc = SYSUTCDATETIME(),
           ExitCode = @ExitCode,
           ErrorNumber = @ErrorNumber,
           ErrorMessage = LEFT(@ErrorMessage, 2048)
     WHERE ExecutionId = @ExecutionId
       AND State IN ('Pending','Running')
       AND RegistrationHash = HASHBYTES('SHA2_256', @RegistrationToken)
       AND (@ProcessId IS NULL OR ProcessId IS NULL OR ProcessId = @ProcessId);

    IF @@ROWCOUNT <> 1
        THROW 51024, 'Completion rejected.', 1;
END;
GO

CREATE OR ALTER PROCEDURE xt.usp_RunRegisteredCommand
    @ProfileId       sysname,
    @ArgumentsJson   nvarchar(max) = N'[]',
    @WorkingDirectory nvarchar(1024) = NULL,
    @ExecutionId     uniqueidentifier OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @Enabled bit,
        @LauncherPath nvarchar(400),
        @ProfilePath nvarchar(400),
        @MaxPayloadCharacters int;

    SELECT @Enabled = Enabled,
           @LauncherPath = LauncherPath,
           @ProfilePath = ProfilePath,
           @MaxPayloadCharacters = MaxPayloadCharacters
    FROM xt.ConfigInstance
    WHERE ConfigId = 1;

    IF ISNULL(@Enabled, 0) = 0
        THROW 51000, 'Registered command wrapper is disabled.', 1;

    IF @ProfileId IS NULL OR @ProfileId LIKE N'%[^A-Za-z0-9_.-]%'
        THROW 51001, 'Invalid profile identifier.', 1;

    IF NOT EXISTS (SELECT 1 FROM xt.CommandProfile WHERE ProfileId = @ProfileId AND Enabled = 1)
        THROW 51002, 'Profile is not enabled.', 1;

    IF ISJSON(@ArgumentsJson) <> 1 OR LEFT(LTRIM(@ArgumentsJson), 1) <> N'['
        THROW 51003, 'ArgumentsJson must be a JSON array.', 1;

    IF EXISTS (SELECT 1 FROM OPENJSON(@ArgumentsJson) WHERE [type] <> 1)
        THROW 51004, 'Every argument must be a JSON string.', 1;

    IF LEN(@ArgumentsJson) > @MaxPayloadCharacters OR LEN(COALESCE(@WorkingDirectory, N'')) > 1024
        THROW 51005, 'Command payload exceeds configured limits.', 1;

    IF @LauncherPath LIKE N'% %' OR @ProfilePath LIKE N'% %'
       OR @LauncherPath LIKE N'%[&|<>^"' + CHAR(13) + CHAR(10) + N']%'
       OR @ProfilePath LIKE N'%[&|<>^"' + CHAR(13) + CHAR(10) + N']%'
        THROW 51006, 'Launcher and profile paths contain characters that are unsafe for xp_cmdshell invocation.', 1;

    DECLARE @Payload nvarchar(max) =
    (
        SELECT @ArgumentsJson AS argumentsJson,
               @WorkingDirectory AS workingDirectory
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    );

    DECLARE @RegistrationToken varbinary(32) = CRYPT_GEN_RANDOM(32);
    SET @ExecutionId = NEWID();

    INSERT xt.ExecutionRegistry
        (ExecutionId, InstanceName, DatabaseName, SessionId, RequestId, ProfileId,
         ArgumentsHash, RegistrationHash, RequestedUtc, State,
         CallerLogin, CallerHost, CallerProgram)
    SELECT
        @ExecutionId,
        CAST(SERVERPROPERTY('ServerName') AS sysname),
        DB_NAME(),
        @@SPID,
        r.request_id,
        @ProfileId,
        HASHBYTES('SHA2_256', CONVERT(varbinary(max), @Payload)),
        HASHBYTES('SHA2_256', @RegistrationToken),
        SYSUTCDATETIME(),
        'Pending',
        ORIGINAL_LOGIN(),
        HOST_NAME(),
        PROGRAM_NAME()
    FROM (SELECT 1 AS n) AS seed
    LEFT JOIN sys.dm_exec_requests AS r ON r.session_id = @@SPID;

    DECLARE
        @ServerBytes varbinary(max) = CONVERT(varbinary(max), CONVERT(nvarchar(256), SERVERPROPERTY('ServerName'))),
        @DatabaseBytes varbinary(max) = CONVERT(varbinary(max), CONVERT(nvarchar(256), DB_NAME())),
        @PayloadBytes varbinary(max) = CONVERT(varbinary(max), @Payload),
        @ServerB64 varchar(max),
        @DatabaseB64 varchar(max),
        @PayloadB64 varchar(max),
        @TokenB64 varchar(64),
        @Invocation varchar(8000),
        @ReturnCode int;

    SELECT
        @ServerB64 = CAST(N'' AS xml).value('xs:base64Binary(sql:variable("@ServerBytes"))', 'varchar(max)'),
        @DatabaseB64 = CAST(N'' AS xml).value('xs:base64Binary(sql:variable("@DatabaseBytes"))', 'varchar(max)'),
        @PayloadB64 = CAST(N'' AS xml).value('xs:base64Binary(sql:variable("@PayloadBytes"))', 'varchar(max)'),
        @TokenB64 = CAST(N'' AS xml).value('xs:base64Binary(sql:variable("@RegistrationToken"))', 'varchar(64)');

    SET @Invocation = CONVERT(varchar(8000),
        N'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy AllSigned -File ' + @LauncherPath +
        N' -ExecutionId ' + CONVERT(nvarchar(36), @ExecutionId) +
        N' -ProfileId ' + @ProfileId +
        N' -ServerB64 ' + @ServerB64 +
        N' -DatabaseB64 ' + @DatabaseB64 +
        N' -PayloadB64 ' + @PayloadB64 +
        N' -RegistrationTokenB64 ' + @TokenB64 +
        N' -ProfilePath ' + @ProfilePath);

    IF LEN(@Invocation) >= 8000
    BEGIN
        UPDATE xt.ExecutionRegistry
           SET State = 'LaunchRejected', CompletedUtc = SYSUTCDATETIME(),
               ErrorNumber = 51007, ErrorMessage = N'Encoded invocation exceeds xp_cmdshell limit.'
         WHERE ExecutionId = @ExecutionId;
        THROW 51007, 'Encoded invocation exceeds xp_cmdshell limit.', 1;
    END;

    BEGIN TRY
        EXEC @ReturnCode = master.dbo.xp_cmdshell @Invocation;

        IF @ReturnCode <> 0 AND EXISTS
           (SELECT 1 FROM xt.ExecutionRegistry WHERE ExecutionId = @ExecutionId AND State IN ('Pending','Running'))
        BEGIN
            UPDATE xt.ExecutionRegistry
               SET State = 'Failed', CompletedUtc = SYSUTCDATETIME(), ExitCode = @ReturnCode,
                   ErrorMessage = N'Launcher returned a non-zero status without recording completion.'
             WHERE ExecutionId = @ExecutionId AND State IN ('Pending','Running');
        END;
    END TRY
    BEGIN CATCH
        UPDATE xt.ExecutionRegistry
           SET State = CASE WHEN State = 'Pending' THEN 'LaunchRejected' ELSE 'Failed' END,
               CompletedUtc = SYSUTCDATETIME(), ErrorNumber = ERROR_NUMBER(),
               ErrorMessage = LEFT(ERROR_MESSAGE(), 2048)
         WHERE ExecutionId = @ExecutionId AND State IN ('Pending','Running');
        THROW;
    END CATCH;
END;
GO

IF DATABASE_PRINCIPAL_ID(N'xt_command_executor') IS NULL
    EXEC(N'CREATE ROLE xt_command_executor AUTHORIZATION dbo;');
GO
GRANT EXECUTE ON xt.usp_RunRegisteredCommand TO xt_command_executor;
GO

/*
  Do not grant the registration procedures to public or xt_command_executor.
  Grant them only to the Windows login used by the launcher, for example:

  CREATE USER [DOMAIN\SqlService] FOR LOGIN [DOMAIN\SqlService];
  GRANT EXECUTE ON xt.usp_RegisterProcess TO [DOMAIN\SqlService];
  GRANT EXECUTE ON xt.usp_HeartbeatExecution TO [DOMAIN\SqlService];
  GRANT EXECUTE ON xt.usp_CompleteExecution TO [DOMAIN\SqlService];
*/
