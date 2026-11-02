    ; Abel Doyle
    ; RCET3375
    ; Lab10-2I2C
    ; https://github.com/abeldoyl/Lab-10-I2C/tree/main/Lab10-2I2C.X
    
; PIC16F883 Configuration Bit Settings

; Assembly source line config statements

; CONFIG1
  CONFIG  FOSC = XT             ; Oscillator Selection bits (XT oscillator: Crystal/resonator on RA6/OSC2/CLKOUT and RA7/OSC1/CLKIN)
  CONFIG  WDTE = OFF            ; Watchdog Timer Enable bit (WDT disabled and can be enabled by SWDTEN bit of the WDTCON register)
  CONFIG  PWRTE = OFF           ; Power-up Timer Enable bit (PWRT disabled)
  CONFIG  MCLRE = ON            ; RE3/MCLR pin function select bit (RE3/MCLR pin function is MCLR)
  CONFIG  CP = OFF              ; Code Protection bit (Program memory code protection is disabled)
  CONFIG  CPD = OFF             ; Data Code Protection bit (Data memory code protection is disabled)
  CONFIG  BOREN = OFF           ; Brown Out Reset Selection bits (BOR disabled)
  CONFIG  IESO = OFF            ; Internal External Switchover bit (Internal/External Switchover mode is disabled)
  CONFIG  FCMEN = OFF           ; Fail-Safe Clock Monitor Enabled bit (Fail-Safe Clock Monitor is disabled)
  CONFIG  LVP = OFF             ; Low Voltage Programming Enable bit (RB3 pin has digital I/O, HV on MCLR must be used for programming)

; CONFIG2
  CONFIG  BOR4V = BOR40V        ; Brown-out Reset Selection bit (Brown-out Reset set to 4.0V)
  CONFIG  WRT = OFF             ; Flash Program Memory Self Write Enable bits (Write protection off)

; config statements should precede project file includes.
#include <xc.inc>
; ======================================================================
; Constants
; ======================================================================
 ADS_ADDR      EQU 0x48        ; 7-bit ADS1115 address (0x48-0x4B); use the one your probe confirmed
 
 SSPADD_VAL    EQU 9           ; 4 MHz / (4 * 100 kHz) - 1 = 9 -> 100 kHz
 SSPSTAT_VAL   EQU 0x80        ; slew-rate control off (100 kHz mode)
 SSPCON_VAL    EQU 0x28        ; SSPEN = 1, I2C master mode
 
; ADS1115 register pointers
 REG_CONVERSION EQU 0x00
 REG_CONFIG     EQU 0x01
 REG_LO_THRESH  EQU 0x02
 REG_HI_THRESH  EQU 0x03
 
; ---- TODO: derive these from the ADS1115 data sheet ----
 CONFIG_MSB     EQU 0x40       ; Step 3: AIN0 vs GND, +/-6.144 V, continuous, 128 SPS, comparator off
 CONFIG_LSB     EQU 0x83
 LO_MSB         EQU 0x00       ; Step 5: Lo_thresh (see "Conversion Ready Pin")
 LO_LSB         EQU 0x00
 HI_MSB         EQU 0x80       ; Step 5: Hi_thresh
 HI_LSB         EQU 0x00
 CONFIG_RDY_MSB EQU 0x40       ; Step 5: Step 3 Config with the conversion-ready output enabled
 CONFIG_RDY_LSB EQU 0x80
  
; Timer1 runs 1 us per tick (1:1, Fosc/4). Interval = 65536 - preload, in us.
; 0x0000 = 65.536 ms (the Part 1 interval). Choose your own for Step 5/6.
 ;RELOAD_H       EQU 0x00
 ;RELOAD_L       EQU 0x00

;Timer1 values for Steps 5/6
 RELOAD_H	 EQU 0xEC
 RELOAD_L	 EQU 0X78
	 
; Result codes kept in i2c_result (shown on RB2:RB0)
RES_OK         EQU 0
RES_NACK       EQU 1
RES_TIMEOUT    EQU 2
RES_BUS_LOW    EQU 3
 
; Bit numbers
BIT_TMR1ON     EQU 0          ; T1CON
BIT_TMR1IF     EQU 0          ; PIR1
BIT_SSPIF      EQU 3          ; PIR1
BIT_SEN        EQU 0          ; SSPCON2
BIT_PEN        EQU 2
BIT_RCEN       EQU 3
BIT_ACKEN      EQU 4
BIT_ACKDT      EQU 5
BIT_ACKSTAT    EQU 6
C_BIT          EQU 0          ; STATUS carry
Z_BIT          EQU 2          ; STATUS zero
TRIG_BIT       EQU 1          ; RA1 = scope trigger / transaction frame (same as Part 1)
SCL_BIT        EQU 3          ; RC3
SDA_BIT        EQU 4          ; RC4
 
; ======================================================================
; Variables (Bank 0)
; ======================================================================
PSECT udata_bank0
i2c_address:   DS 1           ; 7-bit address
i2c_ptr:       DS 1           ; buffer address for the current transaction
i2c_count:     DS 1           ; data bytes left
i2c_result:    DS 1           ; RES_* code
i2c_byte:      DS 1           ; scratch for the address byte
wait_lo:       DS 1           ; bounded-wait counters
wait_hi:       DS 1
tx_buf:        DS 3           ; pointer, MSB, LSB
rx_buf:        DS 2           ; MSB, LSB (Config or ADC result)
 
; ======================================================================
; Vectors
; ======================================================================
PSECT resetVect,class=CODE,delta=2
ResetVector:
    goto Setup
 
PSECT code,class=CODE,delta=2
 
; ======================================================================
; Setup (common to every step)
; ======================================================================
Setup:
    CLRF INTCON                 ; polled, no interrupts
 
    BANKSEL PORTA
    CLRF PORTA
    CLRF PORTB
 
    BANKSEL TRISA
    BCF TRISA,TRIG_BIT          ; RA1 output: scope trigger
    CLRF TRISB                  ; RB2:RB0 output: result code (change if these pins are in use)
    BSF TRISC,SCL_BIT           ; MSSP drives SCL/SDA
    BSF TRISC,SDA_BIT
 
    BANKSEL ANSEL
    CLRF ANSEL                  ; all pins digital
    CLRF ANSELH
 
    BANKSEL SSPADD
    MOVLW SSPADD_VAL
    MOVWF SSPADD
    BANKSEL SSPSTAT
    MOVLW SSPSTAT_VAL
    MOVWF SSPSTAT
    BANKSEL SSPCON2
    CLRF SSPCON2
    BANKSEL SSPCON
    MOVLW SSPCON_VAL            ; enable MSSP last
    MOVWF SSPCON
 
    BANKSEL T1CON
    CLRF T1CON                  ; Timer1 off, 1:1, internal clock
 
    BANKSEL i2c_address
    MOVLW ADS_ADDR
    MOVWF i2c_address
    CLRF i2c_result
 
; ======================================================================
; Main: one block per lab step
; ======================================================================
Main:
    ; Leave exactly one step active. One-shot steps return here and fall into Idle.
    ;CALL Step1_Probe
    ;CALL Step2_ReadConfig
    ;CALL Step3_WriteConfig
    ;CALL Step3_VerifyConfig
    ;CALL Step4_Poll
    ;CALL Step5_EnableReady
    CALL Step6_Final
 
Idle:
    goto Idle                   ; do-nothing loop for Single Sequence captures
 
; ======================================================================
; Lab steps (each is one CALL from Main)
; ======================================================================
 
; Step 1: START, ADDR+W, ACK/NACK, STOP
Step1_Probe:
    BANKSEL PORTA
    BSF PORTA,TRIG_BIT
    CLRF i2c_count              ; zero data bytes = address only
    CALL I2CWrite
    BANKSEL PORTA
    BCF PORTA,TRIG_BIT
    goto ShowResult             ; 0 = ACK, 1 = NACK
 
; Step 2: select Config pointer, then read Config (expect 0x8583 after power-up)
Step2_ReadConfig:
    MOVLW REG_CONFIG
    CALL SelectPointer          ; START, ADDR+W, ACK, 0x01, ACK, STOP
    MOVF i2c_result,F
    BTFSS STATUS,Z_BIT
    RETURN                      ; pointer write failed: skip the read
    goto ReadReg16              ; START, ADDR+R, ACK, MSB, ACK, LSB, NACK, STOP -> rx_buf
 
; Step 3: write Config once
Step3_WriteConfig:
    BANKSEL PORTA
    BSF PORTA,TRIG_BIT
    CALL ConfigureADC
    BANKSEL PORTA
    BCF PORTA,TRIG_BIT
    RETURN
 
; Step 3 verify: read Config back (the write left the pointer on Config)
Step3_VerifyConfig:
    goto ReadReg16
 
; Step 4: configure once, then poll (never returns)
Step4_Poll:
    CALL ConfigureADC
    MOVF i2c_result,F
    BTFSS STATUS,Z_BIT
    RETURN                      ; Config write failed: hold the error code
    goto PollForever
    
; Step 5: Lo/Hi thresholds + Config with RDY enabled, once
Step5_EnableReady:
    goto EnableReady
 
; Step 6: configure, enable RDY, then poll (never returns)
Step6_Final:
    CALL ConfigureADC
    MOVF i2c_result,F
    BTFSS STATUS,Z_BIT
    RETURN                      ; Config write failed: hold the error code
    CALL EnableReady
    MOVF i2c_result,F
    BTFSS STATUS,Z_BIT
    RETURN                      ; RDY setup failed: hold the error code
    goto PollForever
 
; Read the Conversion register once per Timer1 interval
PollForever:
    CALL ReloadTimer1
PollLoop:
    BANKSEL PIR1
    BTFSS PIR1,BIT_TMR1IF       ; wait for the polling interval
    goto PollLoop
    CALL ReloadTimer1           ; clear flag, start the next interval
    BANKSEL PORTA
    BSF PORTA,TRIG_BIT          ; frame the read cycle for the scope
    CALL ReadConversion         ; pointer write + 2-byte read -> rx_buf
    BANKSEL PORTA
    BCF PORTA,TRIG_BIT
    goto PollLoop
 
; ======================================================================
; Level 3: ADS1115 application (all routines enter and leave in Bank 0)
; ======================================================================
 
; Write Config pointer + two Config bytes
ConfigureADC:
    MOVLW REG_CONFIG
    MOVWF tx_buf
    MOVLW CONFIG_MSB
    MOVWF tx_buf+1
    MOVLW CONFIG_LSB
    MOVWF tx_buf+2
    goto WriteReg16             ; tail call
 
; Lo_thresh, Hi_thresh, then Config with RDY enabled; stops at the first error
EnableReady:
    MOVLW REG_LO_THRESH
    MOVWF tx_buf
    MOVLW LO_MSB
    MOVWF tx_buf+1
    MOVLW LO_LSB
    MOVWF tx_buf+2
    CALL WriteReg16
    MOVF i2c_result,F
    BTFSS STATUS,Z_BIT
    RETURN
 
    MOVLW REG_HI_THRESH
    MOVWF tx_buf
    MOVLW HI_MSB
    MOVWF tx_buf+1
    MOVLW HI_LSB
    MOVWF tx_buf+2
    CALL WriteReg16
    MOVF i2c_result,F
    BTFSS STATUS,Z_BIT
    RETURN
 
    MOVLW REG_CONFIG
    MOVWF tx_buf
    MOVLW CONFIG_RDY_MSB
    MOVWF tx_buf+1
    MOVLW CONFIG_RDY_LSB
    MOVWF tx_buf+2
    goto WriteReg16             ; tail call
 
; Select Conversion register, then read two bytes (read skipped if the pointer write fails)
ReadConversion:
    MOVLW REG_CONVERSION
    CALL SelectPointer
    MOVF i2c_result,F
    BTFSS STATUS,Z_BIT
    RETURN
    goto ReadReg16              ; tail call
 
; Send tx_buf[0..2] (pointer, MSB, LSB)
WriteReg16:
    MOVLW tx_buf
    MOVWF i2c_ptr
    MOVLW 3
    MOVWF i2c_count
    CALL I2CWrite
    goto ShowResult
 
; W = register pointer; sends the one-byte pointer write
SelectPointer:
    MOVWF tx_buf
    MOVLW tx_buf
    MOVWF i2c_ptr
    MOVLW 1
    MOVWF i2c_count
    CALL I2CWrite
    goto ShowResult
 
; Read two bytes into rx_buf (MSB first). Valid only if i2c_result = 0 afterwards.
ReadReg16:
    CLRF rx_buf
    CLRF rx_buf+1
    MOVLW rx_buf
    MOVWF i2c_ptr
    MOVLW 2
    MOVWF i2c_count
    CALL I2CRead
    goto ShowResult
 
ShowResult:
    BANKSEL PORTB
    MOVF i2c_result,W
    MOVWF PORTB
    RETURN
 
; Clear the flag, load the preload, start Timer1
ReloadTimer1:
    BANKSEL T1CON
    BCF T1CON,BIT_TMR1ON
    MOVLW RELOAD_H
    MOVWF TMR1H
    MOVLW RELOAD_L
    MOVWF TMR1L
    BCF PIR1,BIT_TMR1IF
    BSF T1CON,BIT_TMR1ON
    RETURN
 
; ======================================================================
; Level 2: transactions
;   Inputs:  i2c_address, i2c_ptr, i2c_count
;   Output:  i2c_result
;   Rules:   NACK  -> stop sending data, attempt STOP, keep NACK
;            error -> report it, no STOP assumed
; ======================================================================
 
; Address + W, then i2c_count bytes from (i2c_ptr). Count 0 = address probe.
I2CWrite:
    CLRF i2c_result
    CALL I2CStart
    MOVF i2c_result,F
    BTFSS STATUS,Z_BIT
    goto WriteDone
 
    BCF STATUS,C_BIT            ; write bit = 0
    MOVF i2c_address,W
    MOVWF i2c_byte
    RLF i2c_byte,W              ; W = (address << 1) | 0
    CALL I2CSendByte
    MOVF i2c_result,F
    BTFSS STATUS,Z_BIT
    goto WriteDone
 
WriteLoop:
    MOVF i2c_count,F
    BTFSC STATUS,Z_BIT
    goto WriteDone              ; no bytes left
    MOVF i2c_ptr,W
    MOVWF FSR
    MOVF INDF,W
    CALL I2CSendByte
    MOVF i2c_result,F
    BTFSS STATUS,Z_BIT
    goto WriteDone
    INCF i2c_ptr,F
    DECF i2c_count,F
    goto WriteLoop
 
WriteDone:
    goto I2CFinish              ; tail call
 
; Address + R, then i2c_count (>= 1) bytes into (i2c_ptr): ACK each, NACK the last
I2CRead:
    CLRF i2c_result
    CALL I2CStart
    MOVF i2c_result,F
    BTFSS STATUS,Z_BIT
    goto ReadDone
 
    BSF STATUS,C_BIT            ; read bit = 1
    MOVF i2c_address,W
    MOVWF i2c_byte
    RLF i2c_byte,W              ; W = (address << 1) | 1
    CALL I2CSendByte
    MOVF i2c_result,F
    BTFSS STATUS,Z_BIT
    goto ReadDone
 
ReadLoop:
    CALL I2CReceive             ; byte -> (i2c_ptr)
    MOVF i2c_result,F
    BTFSS STATUS,Z_BIT
    goto ReadDone
    INCF i2c_ptr,F
    DECFSZ i2c_count,F
    goto ReadMore
    CALL I2CSendNack            ; last byte: tell the slave to stop
    goto ReadDone
ReadMore:
    CALL I2CSendAck             ; more to come
    MOVF i2c_result,F
    BTFSS STATUS,Z_BIT
    goto ReadDone
    goto ReadLoop
 
ReadDone:
    goto I2CFinish              ; tail call
 
; STOP after OK or NACK; nothing after a timeout or bus-low error.
; A STOP timeout replaces the earlier result.
I2CFinish:
    MOVF i2c_result,W
    BTFSC STATUS,Z_BIT
    goto FinishStop             ; OK
    XORLW RES_NACK
    BTFSS STATUS,Z_BIT
    RETURN                      ; timeout or bus low: do not try STOP
FinishStop:
    goto I2CStop                ; tail call
 
; ======================================================================
; Level 1: MSSP operations (Bank 0 on entry and exit)
; ======================================================================
 
; START, after checking SCL and SDA are both high
I2CStart:
    BANKSEL PORTC
    BTFSS PORTC,SCL_BIT
    goto StartBusLow
    BTFSS PORTC,SDA_BIT
    goto StartBusLow
    BANKSEL PIR1
    BCF PIR1,BIT_SSPIF
    BANKSEL SSPCON2
    BSF SSPCON2,BIT_SEN
    BANKSEL PIR1
    goto I2CWait
StartBusLow:
    BANKSEL i2c_result
    MOVLW RES_BUS_LOW
    MOVWF i2c_result
    RETURN
 
; W = byte to send. Sets RES_NACK if the slave does not ACK.
I2CSendByte:
    BANKSEL PIR1
    BCF PIR1,BIT_SSPIF
    BANKSEL SSPBUF
    MOVWF SSPBUF                ; starts the 9 clocks
    CALL I2CWait
    MOVF i2c_result,F
    BTFSS STATUS,Z_BIT
    RETURN                      ; timeout
    BANKSEL SSPCON2
    BTFSC SSPCON2,BIT_ACKSTAT   ; 1 = NACK
    goto SendNack
    BANKSEL PIR1
    RETURN
SendNack:
    BANKSEL i2c_result
    MOVLW RES_NACK
    MOVWF i2c_result
    RETURN
 
; Receive one byte and store it at (i2c_ptr)
I2CReceive:
    BANKSEL PIR1
    BCF PIR1,BIT_SSPIF
    BANKSEL SSPCON2
    BSF SSPCON2,BIT_RCEN
    BANKSEL PIR1
    CALL I2CWait
    MOVF i2c_result,F
    BTFSS STATUS,Z_BIT
    RETURN
    MOVF i2c_ptr,W
    MOVWF FSR
    BANKSEL SSPBUF
    MOVF SSPBUF,W
    MOVWF INDF
    RETURN
 
; Master ACK after a received byte (more data wanted)
I2CSendAck:
    BANKSEL SSPCON2
    BCF SSPCON2,BIT_ACKDT
    goto AckCommon
 
; Master NACK after the last received byte
I2CSendNack:
    BANKSEL SSPCON2
    BSF SSPCON2,BIT_ACKDT
AckCommon:
    BANKSEL PIR1
    BCF PIR1,BIT_SSPIF
    BANKSEL SSPCON2
    BSF SSPCON2,BIT_ACKEN
    BANKSEL PIR1
    goto I2CWait
 
I2CStop:
    BANKSEL PIR1
    BCF PIR1,BIT_SSPIF
    BANKSEL SSPCON2
    BSF SSPCON2,BIT_PEN
    BANKSEL PIR1
    goto I2CWait
 
; Wait for SSPIF with a time limit (~8 ms). On timeout: i2c_result = RES_TIMEOUT.
I2CWait:
    MOVLW 8
    MOVWF wait_hi
    CLRF wait_lo
WaitLoop:
    BTFSC PIR1,BIT_SSPIF
    goto WaitDone
    DECFSZ wait_lo,F
    goto WaitLoop
    DECFSZ wait_hi,F
    goto WaitLoop
    MOVLW RES_TIMEOUT
    MOVWF i2c_result
    RETURN
WaitDone:
    BCF PIR1,BIT_SSPIF
    RETURN
 
End
 