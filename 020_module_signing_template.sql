/*
  TEMPLATE: sign xt.usp_RunRegisteredCommand so ordinary callers do not need
  direct EXECUTE on master.dbo.xp_cmdshell or VIEW SERVER STATE.

  Run in SQLCMD mode after replacing the variables below. The certificate file
  contains only the public certificate, but its directory must still be
  protected and cleaned up according to the deployment standard.

  IMPORTANT: ADD SIGNATURE must be repeated after every ALTER PROCEDURE.
*/
:setvar MonitorDatabase "DBA"
:setvar CertificateFile "C:\ProgramData\SqlXpcmd\deployment\xt_wrapper_permission.cer"
:setvar CertificatePassword "REPLACE_AT_DEPLOYMENT_DO_NOT_COMMIT"

USE [$(MonitorDatabase)];
GO

IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = N'xt_wrapper_permission')
BEGIN
    CREATE CERTIFICATE xt_wrapper_permission
        ENCRYPTION BY PASSWORD = '$(CertificatePassword)'
        WITH SUBJECT = 'Permissions for registered xp_cmdshell wrapper only',
             EXPIRY_DATE = '2035-12-31';
END;
GO

IF EXISTS
(
    SELECT 1
    FROM sys.crypt_properties AS cp
    JOIN sys.certificates AS c ON c.thumbprint = cp.thumbprint
    WHERE cp.class_desc = N'OBJECT_OR_COLUMN'
      AND cp.major_id = OBJECT_ID(N'xt.usp_RunRegisteredCommand')
      AND c.name = N'xt_wrapper_permission'
)
    DROP SIGNATURE FROM OBJECT::xt.usp_RunRegisteredCommand
        BY CERTIFICATE xt_wrapper_permission;
GO

ADD SIGNATURE TO OBJECT::xt.usp_RunRegisteredCommand
    BY CERTIFICATE xt_wrapper_permission
    WITH PASSWORD = '$(CertificatePassword)';
GO

BACKUP CERTIFICATE xt_wrapper_permission
    TO FILE = '$(CertificateFile)';
GO

USE master;
GO

IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = N'xt_wrapper_permission_public')
BEGIN
    CREATE CERTIFICATE xt_wrapper_permission_public
        FROM FILE = '$(CertificateFile)';
END;
GO

IF SUSER_ID(N'xt_wrapper_permission_login') IS NULL
    CREATE LOGIN xt_wrapper_permission_login
        FROM CERTIFICATE xt_wrapper_permission_public;
GO

GRANT EXECUTE ON dbo.xp_cmdshell TO xt_wrapper_permission_login;
GRANT VIEW SERVER STATE TO xt_wrapper_permission_login;
GO

/* Verification: the module must have exactly one signature by this certificate. */
USE [$(MonitorDatabase)];
GO
IF NOT EXISTS
(
    SELECT 1
    FROM sys.crypt_properties AS cp
    JOIN sys.certificates AS c
      ON c.thumbprint = cp.thumbprint
    WHERE cp.class_desc = N'OBJECT_OR_COLUMN'
      AND cp.major_id = OBJECT_ID(N'xt.usp_RunRegisteredCommand')
      AND c.name = N'xt_wrapper_permission'
)
    THROW 51100, 'Wrapper procedure is not signed.', 1;
GO
