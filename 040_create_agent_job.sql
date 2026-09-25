/*
  Creates the one-minute monitor job. Run in SQLCMD mode after setting the
  monitor database. The termination configuration remains disabled by default.
*/
:setvar MonitorDatabase "DBA"

USE msdb;
GO

IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = N'xp_cmdshell Safe Monitor')
    EXEC dbo.sp_delete_job @job_name = N'xp_cmdshell Safe Monitor';
GO

EXEC dbo.sp_add_job
    @job_name = N'xp_cmdshell Safe Monitor',
    @enabled = 0,
    @description = N'Collects registered xp_cmdshell blockers, evaluates safety rules, and dispatches only explicitly enabled actions.',
    @owner_login_name = N'sa';
GO

EXEC dbo.sp_add_jobstep
    @job_name = N'xp_cmdshell Safe Monitor',
    @step_name = N'Collect evaluate and verify',
    @subsystem = N'TSQL',
    @database_name = N'$(MonitorDatabase)',
    @command = N'EXEC xt.usp_MonitorCycle;',
    @retry_attempts = 1,
    @retry_interval = 1,
    @on_success_action = 1,
    @on_fail_action = 2;
GO

EXEC dbo.sp_add_schedule
    @schedule_name = N'xp_cmdshell Safe Monitor Every Minute',
    @enabled = 1,
    @freq_type = 4,
    @freq_interval = 1,
    @freq_subday_type = 4,
    @freq_subday_interval = 1,
    @active_start_time = 0;
GO

EXEC dbo.sp_attach_schedule
    @job_name = N'xp_cmdshell Safe Monitor',
    @schedule_name = N'xp_cmdshell Safe Monitor Every Minute';
GO

EXEC dbo.sp_add_jobserver @job_name = N'xp_cmdshell Safe Monitor';
GO

/* Enable only after audit-only configuration and test validation. */
-- EXEC dbo.sp_update_job @job_name = N'xp_cmdshell Safe Monitor', @enabled = 1;
GO

