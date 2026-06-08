@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0\.."

REM -----------------------------------------------------------------------------
REM Script: build_llvm_unsafe.cmd
REM Description: Builds optimized native binaries with LLVM/ClangCL, tuned for the
REM              local machine and without requiring Spectre libraries.
REM -----------------------------------------------------------------------------

REM Initialize script state, tool paths, and build settings.
set "ExitCode=0"
set "IsCI=false"
set "BuildTerminalLogger=auto"
set "VSINSTALLPATH="
set "VSWHERE="
set "LLVMINSTALLDIR="
set "LLVMTOOLSVERSION="
set "LOCAL_ARCH=%PROCESSOR_ARCHITECTURE%"
set "HOST_ARCH=%PROCESSOR_ARCHITECTURE%"
set "PLATFORM="
set "VCVARS_ARCH="
set "CustomBuildTool=tools\CustomBuildTool\bin\Release\%PROCESSOR_ARCHITECTURE%\CustomBuildTool.exe"

if defined PROCESSOR_ARCHITEW6432 set "LOCAL_ARCH=%PROCESSOR_ARCHITEW6432%"

REM Run the main script flow and capture the final exit code.
call :DetectCi
call :ConfigureBuildLogger
call :Main
if errorlevel 1 set "ExitCode=%errorlevel%"

:end
REM Pause only for interactive, non-CI invocations before returning.
if /i "%IsCI%"=="false" call :PauseIfInteractive
endlocal & exit /b %ExitCode%

REM -----------------------------------------------------------------------------
REM Function: Main
REM Description: Resolves the native platform and runs LLVM unsafe Release builds.
REM -----------------------------------------------------------------------------
:Main
call :ResolveLocalPlatform
if errorlevel 1 exit /b %errorlevel%

call :FindVisualStudio
if errorlevel 1 exit /b %errorlevel%

call :FindLlvm
if errorlevel 1 exit /b %errorlevel%

call :SetupVcVars "%VCVARS_ARCH%"
if errorlevel 1 exit /b %errorlevel%

set "PATH=%LLVMINSTALLDIR%\bin;%PATH%"
set "SI_UNSAFE_BUILD=true"
set "SI_LLVM_BUILD=true"
set "SI_LLVM_LTO=true"
set "SI_LLVM_NATIVE=true"
set "SpectreMitigation=false"
set "Driver_SpectreMitigation=false"

echo:
echo Building LLVM unsafe Release for %PLATFORM%
echo LLVM: %LLVMINSTALLDIR%
echo LLVM tools version: %LLVMTOOLSVERSION%
echo Spectre mitigation libraries are not required for this build.
echo LLVM full LTO is enabled through /clang:-flto=full and lld-link.
echo Function and data section splitting are enabled for linker garbage collection.
echo Native code generation is enabled through /clang:-march=native.

call :RunMsBuild "tools\thirdparty\thirdparty.sln" "thirdparty.sln [%PLATFORM%]" "Rebuild"
if errorlevel 1 exit /b %errorlevel%

call :CheckCustomBuildTool
if errorlevel 1 exit /b %errorlevel%

call :RunMsBuild "SystemInformer.sln" "SystemInformer.sln [%PLATFORM%]"
if errorlevel 1 exit /b %errorlevel%

call :RunMsBuild "Plugins\Plugins.sln" "Plugins.sln [%PLATFORM%]"
if errorlevel 1 exit /b %errorlevel%

exit /b 0

REM -----------------------------------------------------------------------------
REM Function: ResolveLocalPlatform
REM Description: Maps the local machine architecture to MSBuild and vcvars values.
REM -----------------------------------------------------------------------------
:ResolveLocalPlatform
if /i "%LOCAL_ARCH%"=="AMD64" (
    set "PLATFORM=x64"
    set "VCVARS_ARCH=amd64"
    exit /b 0
)

if /i "%LOCAL_ARCH%"=="ARM64" (
    set "PLATFORM=ARM64"
    set "VCVARS_ARCH=arm64"
    if /i not "%HOST_ARCH%"=="ARM64" set "VCVARS_ARCH=amd64_arm64"
    exit /b 0
)

if /i "%LOCAL_ARCH%"=="x86" (
    set "PLATFORM=Win32"
    set "VCVARS_ARCH=x86"
    exit /b 0
)

echo Unsupported processor architecture: %LOCAL_ARCH%
exit /b 1

REM -----------------------------------------------------------------------------
REM Function: RunMsBuild
REM Description: Builds a solution in Release for the resolved native platform.
REM Parameters:
REM   %~1 - Solution path.
REM   %~2 - Friendly label shown in output.
REM   %~3 - Optional target used by the All target for each project.
REM -----------------------------------------------------------------------------
:RunMsBuild
set "BUILD_ALL_TARGET=%~3"
if "%BUILD_ALL_TARGET%"=="" set "BUILD_ALL_TARGET=Build"
echo:
echo Building %~2
msbuild /m /graph %~1 -t:All -p:BuildAllTarget=%BUILD_ALL_TARGET% -p:Configuration=Release -p:Platform=%PLATFORM% -p:TargetConfigurations="Release" -p:TargetPlatforms="%PLATFORM%" -p:DefaultPlatformToolset=ClangCL -p:LLVMInstallDir="%LLVMINSTALLDIR%\\" -p:LLVMToolsVersion=%LLVMTOOLSVERSION% -p:SI_UNSAFE_BUILD=true -p:SI_LLVM_BUILD=true -p:SI_LLVM_LTO=true -p:SI_LLVM_NATIVE=true -p:SpectreMitigation=false -p:Driver_SpectreMitigation=false -p:RestoreUseStaticGraphEvaluation=true -p:CopyRetryCount=10 -p:CopyRetryDelayMilliseconds=200 -terminalLogger:%BuildTerminalLogger%
exit /b %errorlevel%

REM -----------------------------------------------------------------------------
REM Function: CheckCustomBuildTool
REM Description: Ensures post-build helper tools are available.
REM -----------------------------------------------------------------------------
:CheckCustomBuildTool
if exist "%CustomBuildTool%" exit /b 0
echo CustomBuildTool.exe not found. Run build\build_init.cmd first.
exit /b 1

REM -----------------------------------------------------------------------------
REM Function: FindVisualStudio
REM Description: Locates a Visual Studio or SDK installation with MSBuild.
REM -----------------------------------------------------------------------------
:FindVisualStudio
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" set "VSWHERE=%ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "%VSWHERE%" (
    for /f "usebackq tokens=*" %%a in (`call "%VSWHERE%" -latest -prerelease -products * -requires Microsoft.Component.MSBuild -property installationPath`) do (
       set "VSINSTALLPATH=%%a"
    )
)
if not defined VSINSTALLPATH if defined VSINSTALLDIR set "VSINSTALLPATH=%VSINSTALLDIR%"
if not defined VSINSTALLPATH if defined VCINSTALLDIR for %%I in ("%VCINSTALLDIR%\..\..") do set "VSINSTALLPATH=%%~fI"
if not defined VSINSTALLPATH if defined WindowsSdkDir set "VSINSTALLPATH=%WindowsSdkDir%"
if defined VSINSTALLPATH exit /b 0
echo No Visual Studio installation detected.
exit /b 1

REM -----------------------------------------------------------------------------
REM Function: FindLlvm
REM Description: Locates LLVM and the clang resource/tool version used by VS.
REM -----------------------------------------------------------------------------
:FindLlvm
if defined LLVMInstallDir set "LLVMINSTALLDIR=%LLVMInstallDir%"
if not defined LLVMINSTALLDIR if defined LLVMINSTALLDIR set "LLVMINSTALLDIR=%LLVMINSTALLDIR%"
if not defined LLVMINSTALLDIR if exist "%ProgramFiles%\LLVM\bin\clang-cl.exe" set "LLVMINSTALLDIR=%ProgramFiles%\LLVM"
if not defined LLVMINSTALLDIR if exist "%ProgramFiles(x86)%\LLVM\bin\clang-cl.exe" set "LLVMINSTALLDIR=%ProgramFiles(x86)%\LLVM"
if not defined LLVMINSTALLDIR (
    for /f "usebackq tokens=*" %%a in (`where clang-cl.exe 2^>nul`) do (
        if not defined LLVMINSTALLDIR for %%I in ("%%~dpa..") do set "LLVMINSTALLDIR=%%~fI"
    )
)
if not defined LLVMINSTALLDIR (
    echo LLVM clang-cl.exe not found. Install LLVM or set LLVMInstallDir.
    exit /b 1
)
if not exist "%LLVMINSTALLDIR%\bin\clang-cl.exe" (
    echo clang-cl.exe not found under %LLVMINSTALLDIR%\bin.
    exit /b 1
)
for /f "usebackq tokens=*" %%a in (`dir /b /ad /o-n "%LLVMINSTALLDIR%\lib\clang" 2^>nul`) do (
    if not defined LLVMTOOLSVERSION set "LLVMTOOLSVERSION=%%a"
)
if not defined LLVMTOOLSVERSION (
    echo LLVM tools version not found under %LLVMINSTALLDIR%\lib\clang.
    exit /b 1
)
exit /b 0

REM -----------------------------------------------------------------------------
REM Function: SetupVcVars
REM Description: Initializes the Visual C++ build environment for the requested arch.
REM Parameters:
REM   %~1 - vcvarsall architecture argument.
REM -----------------------------------------------------------------------------
:SetupVcVars
if /i "%EnterpriseWDK%"=="true" (
    REM EWDK has already configured INCLUDE/LIB/PATH via LaunchBuildEnv.cmd.
    exit /b 0
)
if exist "%VSINSTALLPATH%\VC\Auxiliary\Build\vcvarsall.bat" (
    call "%VSINSTALLPATH%\VC\Auxiliary\Build\vcvarsall.bat" %~1
    exit /b !errorlevel!
)
echo vcvarsall.bat not found under %VSINSTALLPATH%.
exit /b 1

REM -----------------------------------------------------------------------------
REM Function: DetectCi
REM Description: Detects whether the script is running under CI.
REM -----------------------------------------------------------------------------
:DetectCi
if /i "%GITHUB_ACTIONS%"=="true" set "IsCI=true"
if /i "%TF_BUILD%"=="true" set "IsCI=true"
exit /b 0

REM -----------------------------------------------------------------------------
REM Function: ConfigureBuildLogger
REM Description: Disables the Visual Studio terminal logger when running under CI.
REM -----------------------------------------------------------------------------
:ConfigureBuildLogger
if /i "%IsCI%"=="true" set "BuildTerminalLogger=off"
exit /b 0

REM -----------------------------------------------------------------------------
REM Function: PauseIfInteractive
REM Description: Pauses only when stdin is attached to an interactive console.
REM -----------------------------------------------------------------------------
:PauseIfInteractive
set "STDIN_REDIRECTED=False"
for /f %%i in ('powershell -NoProfile -Command "[Console]::IsInputRedirected"') do set "STDIN_REDIRECTED=%%i"
if /i not "%STDIN_REDIRECTED%"=="True" pause
exit /b 0
