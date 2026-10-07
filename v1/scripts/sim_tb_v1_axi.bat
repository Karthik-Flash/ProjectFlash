@echo off
rem sim_tb_v1_axi.bat -- xsim batch run of tb_v1_axi (top_v1_axi end to end).
rem Runs outside the Vivado project. Work dir: verilog\sim_tb_v1_axi (gitignored).
rem Usage (from anywhere):  v1\scripts\sim_tb_v1_axi.bat
rem Result: last lines of verilog\sim_tb_v1_axi\xsim.log show RESULT: PASS/FAIL.

setlocal
set XBIN=C:\Xilinx\Vivado\2022.2\bin
set REPO=%~dp0..\..
set RTL=%REPO%\v1\rtl
set INC=%REPO%\v1\mem\v1_2\flash_v1_2
set WORK=%REPO%\verilog\sim_tb_v1_axi

if not exist "%WORK%" mkdir "%WORK%"
cd /d "%WORK%"

call "%XBIN%\xvlog.bat" -i "%INC%" ^
    "%RTL%\conv_engine.v" "%RTL%\fmap_ram.v" "%RTL%\gap_unit.v" "%RTL%\fc_unit.v" ^
    "%RTL%\decision.v" "%RTL%\layer_seq.v" "%RTL%\top_v1.v" "%RTL%\top_v1_axi.v" ^
    "%REPO%\v1\sim\tb_v1_axi.v" -log xvlog.log
if errorlevel 1 exit /b 1

call "%XBIN%\xelab.bat" tb_v1_axi -s tb_v1_axi_sim -log xelab.log
if errorlevel 1 exit /b 1

call "%XBIN%\xsim.bat" tb_v1_axi_sim -R -log xsim.log
exit /b %errorlevel%
