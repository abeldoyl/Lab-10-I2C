    ; Abel Doyle
    ; RCET3375
    ; Lab10-3I2C MASTER
    ; https://github.com/abeldoyl/Lab-10-I2C/tree/main/Lab10-3Master.X
    
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
 SLAVE_ADDR    EQU 0x20        ; 7-bit address of the slave PIC
 WRONG_ADDR    EQU 0x3C        ; unrelated address for the NACK test
 
 SSPADD_VAL    EQU 9           ; 4 MHz / (4 * 100 kHz) - 1 = 9 -> 100 kHz
 SSPSTAT_VAL   EQU 0x80        ; slew-rate control off (100 kHz mode)
 SSPCON_VAL    EQU 0x28        ; SSPEN = 1, I2C master mode
 
; Slave register pointers (Part 3 register map)
 PTR_PORTB      EQU 0x00       ; read:  1 byte, RB5:RB0
 PTR_DISPLAY    EQU 0x01       ; write: 1 byte, 7-bit ASCII
 PTR_ADC        EQU 0x02       ; read:  2 bytes, high then low
 PTR_STATUS     EQU 0x04       ; read:  1 byte, device status
 
; Test values
 TEST_BYTE_W    EQU 0xA5       ; Step 2 write test byte
 FIXED_EXPECT   EQU 0x5A       ; Step 2 byte the slave must return
 ECHO_PTR_A     EQU 0xA5       ; Step 3 diagnostic pointer values (slave in echo mode)
 ECHO_PTR_B     EQU 0x3C
 CHAR_1         EQU 0x41       ; Step 5 'A'
 CHAR_2         EQU 0x35       ; Step 5 '5'
 
; Timer1 runs 1 us per tick (1:1, Fosc/4). Interval = 65536 - preload, in us.
; 0x3CB0 -> 65536 - 15536 = 50 ms between poll cycles.
 RELOAD_H       EQU 0x3C
 RELOAD_L       EQU 0xB0
	 
; Result codes kept in i2c_result (shown on RB2:RB0)
RES_OK         EQU 0
RES_NACK       EQU 1
RES_TIMEOUT    EQU 2
RES_BUS_LOW    EQU 3
RES_MISMATCH   EQU 4          ; read worked but data was not what the test expected
 
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
TRIG_BIT       EQU 1          ; RA1 = scope trigger / transaction frame (same as Part 1/2)
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
tx_buf:        DS 3           ; pointer, data, data
rx_buf:        DS 2           ; first byte, second byte
echo_val:      DS 1           ; pointer value being echo-tested (Step 3)
switch_val:    DS 1           ; last PORTB read from slave (RB5:RB0)
status_val:    DS 1           ; last status byte read from slave
adc_h:         DS 1           ; last ADC read: upper 2 bits (masked)
adc_l:         DS 1           ; last ADC read: lower 8 bits
 
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
    MOVLW SLAVE_ADDR
    MOVWF i2c_address
    CLRF i2c_result
    CLRF switch_val
    CLRF status_val
    CLRF adc_h
    CLRF adc_l
 
; ======================================================================
; Main: one block per lab step
; ======================================================================
Main:
    ; Leave exactly one step active. One-shot steps return here and fall into Idle.
    ;CALL Step1_ProbeGood
    ;CALL Step1_ProbeWrong
    ;CALL Step2_WriteByte
    ;CALL Step2_ReadByte
    ;CALL Step3_PointerEcho
    ;CALL Step4_PollSwitches
    ;CALL Step5_Display
    CALL Step6_AdcPoll
 
Idle:
    goto Idle                   ; do-nothing loop for Single Sequence captures
 
; ======================================================================
; Lab steps (each is one CALL from Main)
; ======================================================================
 
; Step 1: START, ADDR+W, ACK/NACK, STOP. Good address (expect ACK, result 0)
Step1_ProbeGood:
    MOVLW SLAVE_ADDR
    goto ProbeAddress
 
; Step 1: same probe with an unrelated address (expect NACK, result 1)
Step1_ProbeWrong:
    MOVLW WRONG_ADDR
    goto ProbeAddress
 
; Step 2: START, 0x40, ACK, 0xA5, ACK, STOP
Step2_WriteByte:
    MOVLW TEST_BYTE_W
    MOVWF tx_buf
    MOVLW tx_buf
    MOVWF i2c_ptr
    MOVLW 1
    MOVWF i2c_count
    BANKSEL PORTA
    BSF PORTA,TRIG_BIT
    CALL I2CWrite
    BANKSEL PORTA
    BCF PORTA,TRIG_BIT
    goto ShowResult
 
; Step 2: START, 0x41, ACK, 0x5A, Master NACK, STOP (result 4 if data != 0x5A)
Step2_ReadByte:
    BANKSEL PORTA
    BSF PORTA,TRIG_BIT
    CALL ReadReg8               ; one byte -> rx_buf, master NACKs it
    BANKSEL PORTA
    BCF PORTA,TRIG_BIT
    MOVF i2c_result,F
    BTFSS STATUS,Z_BIT
    RETURN                      ; read failed: hold the error code
    MOVLW FIXED_EXPECT
    goto CompareRx8
 
; Step 3: select a pointer, read it back (slave in echo mode), twice
Step3_PointerEcho:
    MOVLW ECHO_PTR_A
    CALL EchoTest
    MOVF i2c_result,F
    BTFSS STATUS,Z_BIT
    RETURN
    MOVLW ECHO_PTR_B
    goto EchoTest
 
; Step 4: read PORTB switches and status every Timer1 interval (never returns)
Step4_PollSwitches:
    CALL ReloadTimer1
Step4Loop:
    CALL WaitTick
    BANKSEL PORTA
    BSF PORTA,TRIG_BIT
    CALL ReadSwitches           ; pointer 0x00 + 1-byte read
    CALL ReadStatus             ; pointer 0x04 + 1-byte read
    BANKSEL PORTA
    BCF PORTA,TRIG_BIT
    goto Step4Loop
 
; Step 5: write two characters to the DLG7137 through pointer 0x01, once
Step5_Display:
    MOVLW CHAR_1
    CALL WriteDisplay
    CALL ReadSwitches           ; PORTB and status must still work
    goto ReadStatus
 
; Step 6: read the 10-bit ADC every Timer1 interval (never returns)
Step6_AdcPoll:
    CALL ReloadTimer1
Step6Loop:
    CALL WaitTick
    BANKSEL PORTA
    BSF PORTA,TRIG_BIT
    CALL ReadAdc                ; pointer 0x02 + 2-byte read
    BANKSEL PORTA
    BCF PORTA,TRIG_BIT
    goto Step6Loop

 
; ======================================================================
; Level 3: slave application (all routines enter and leave in Bank 0)
; ======================================================================
 
; W = 7-bit address to probe; START, ADDR+W, ACK/NACK, STOP. Restores SLAVE_ADDR.
ProbeAddress:
    MOVWF i2c_address
    BANKSEL PORTA
    BSF PORTA,TRIG_BIT
    CLRF i2c_count              ; zero data bytes = address only
    CALL I2CWrite
    BANKSEL PORTA
    BCF PORTA,TRIG_BIT
    MOVLW SLAVE_ADDR
    MOVWF i2c_address
    goto ShowResult             ; 0 = ACK, 1 = NACK
 
; W = pointer value. Select it, read one byte, expect the same value back.
EchoTest:
    MOVWF echo_val
    BANKSEL PORTA
    BSF PORTA,TRIG_BIT
    MOVF echo_val,W
    CALL SelectPointer          ; START, 0x40, ACK, ptr, ACK, STOP
    MOVF i2c_result,F
    BTFSS STATUS,Z_BIT
    goto EchoEnd
    CALL ReadReg8               ; START, 0x41, ACK, byte, NACK, STOP
    MOVF i2c_result,F
    BTFSS STATUS,Z_BIT
    goto EchoEnd
    MOVF echo_val,W
    CALL CompareRx8
EchoEnd:
    BANKSEL PORTA
    BCF PORTA,TRIG_BIT
    RETURN
 
; Pointer 0x00: PORTB switches -> rx_buf, switch_val
ReadSwitches:
    MOVLW PTR_PORTB
    CALL SelectPointer
    MOVF i2c_result,F
    BTFSS STATUS,Z_BIT
    RETURN                      ; pointer write failed: skip the read
    CALL ReadReg8
    MOVF i2c_result,F
    BTFSS STATUS,Z_BIT
    RETURN
    MOVF rx_buf,W
    MOVWF switch_val
    RETURN
 
; Pointer 0x04: device status -> rx_buf, status_val
ReadStatus:
    MOVLW PTR_STATUS
    CALL SelectPointer
    MOVF i2c_result,F
    BTFSS STATUS,Z_BIT
    RETURN
    CALL ReadReg8
    MOVF i2c_result,F
    BTFSS STATUS,Z_BIT
    RETURN
    MOVF rx_buf,W
    MOVWF status_val
    RETURN
 
; Pointer 0x02: ADC high then low -> rx_buf, rx_buf+1; adc_h = high & 0x03, adc_l = low
; ADC10 = (adc_h << 8) | adc_l
ReadAdc:
    MOVLW PTR_ADC
    CALL SelectPointer
    MOVF i2c_result,F
    BTFSS STATUS,Z_BIT
    RETURN
    CALL ReadReg16              ; ACK after the high byte, NACK after the low byte
    MOVF i2c_result,F
    BTFSS STATUS,Z_BIT
    RETURN
    MOVF rx_buf,W
    ANDLW 0x03                  ; only bits 9:8 are meaningful
    MOVWF adc_h
    MOVF rx_buf+1,W
    MOVWF adc_l
    RETURN
 
; W = ASCII character; START, 0x40, ACK, 0x01, ACK, char, ACK, STOP
WriteDisplay:
    MOVWF tx_buf+1
    MOVLW PTR_DISPLAY
    MOVWF tx_buf
    MOVLW tx_buf
    MOVWF i2c_ptr
    MOVLW 2
    MOVWF i2c_count
    BANKSEL PORTA
    BSF PORTA,TRIG_BIT
    CALL I2CWrite
    BANKSEL PORTA
    BCF PORTA,TRIG_BIT
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
 
; Read one byte into rx_buf. Master NACKs it (last byte).
ReadReg8:
    CLRF rx_buf
    MOVLW rx_buf
    MOVWF i2c_ptr
    MOVLW 1
    MOVWF i2c_count
    CALL I2CRead
    goto ShowResult
 
; Read two bytes into rx_buf (first byte first). Valid only if i2c_result = 0 afterwards.
ReadReg16:
    CLRF rx_buf
    CLRF rx_buf+1
    MOVLW rx_buf
    MOVWF i2c_ptr
    MOVLW 2
    MOVWF i2c_count
    CALL I2CRead
    goto ShowResult
 
; W = expected value. Result becomes RES_MISMATCH if rx_buf[0] differs.
CompareRx8:
    XORWF rx_buf,W
    BTFSC STATUS,Z_BIT
    RETURN                      ; match: result stays 0
    MOVLW RES_MISMATCH
    MOVWF i2c_result
    goto ShowResult
 
ShowResult:
    BANKSEL PORTB
    MOVF i2c_result,W
    MOVWF PORTB
    RETURN
 
; Wait for Timer1 to roll over, then restart it for the next interval
WaitTick:
    BANKSEL PIR1
    BTFSS PIR1,BIT_TMR1IF
    goto WaitTick
    goto ReloadTimer1           ; tail call: clear flag, start the next interval
 
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
; Level 2: transactions (unchanged from Part 2)
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
; Level 1: MSSP operations (Bank 0 on entry and exit; unchanged from Part 2)
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
; This is the limit to compare with the slave's clock-stretch time in Step 4.
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