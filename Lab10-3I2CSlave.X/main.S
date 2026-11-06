    ; Abel Doyle
    ; RCET3375
    ; Lab10-3I2C SLAVE
    ; https://github.com/abeldoyl/Lab-10-I2C/tree/main/Lab10-3Slave.X
    
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
 SLAVE_ADDR    EQU 0x20        ; 7-bit slave address
 SSPADD_VAL    EQU 0x40        ; SLAVE_ADDR << 1 (SSPADD holds the address in bits 7:1)
 SSPSTAT_VAL   EQU 0x80        ; SMP = 1: slew-rate control off (100 kHz mode)
 SSPCON_VAL    EQU 0x36        ; SSPEN = 1, CKP = 1, SSPM = 0110 (I2C slave, 7-bit, polled)
 SSPCON2_VAL   EQU 0x00        ; SEN = 0: no stretching on receive, GCEN off
 
 ADCON1_VAL    EQU 0x80        ; ADFM = 1 (right justified), VCFG = VDD/VSS
 ADCON0_VAL    EQU 0x49        ; ADCS = Fosc/8 (2 us TAD at 4 MHz), CHS = AN2, ADON = 1
 ANSEL_VAL     EQU 0x04        ; only AN2 analog
 
; ---- Diagnostic modes for Steps 2 and 3 (set DIAG_MODE, rebuild, program) ----
 DIAG_FULL     EQU 0           ; final register map (Steps 3-6)
 DIAG_FIXED    EQU 1           ; Step 2: ACK any write byte, return FIXED_BYTE on read
 DIAG_ECHO     EQU 2           ; Step 3 diagnostic: accept any pointer, echo it on read
 DIAG_MODE     EQU DIAG_FULL
 FIXED_BYTE    EQU 0x5A
 
; ---- Clock-stretching experiment (Step 4) ----
; Delay in the PORTB read path = 3 us * (STRETCH_H:STRETCH_L) at 4 MHz.
;   0 -> 0x0000     100 us -> 0x0021     1 ms -> 0x014D     10 ms -> 0x0D05
; Measure the real SCL LOW time on the scope; do not trust the calculation.
 STRETCH_H     EQU 0x00
 STRETCH_L     EQU 0x21
 
; Register pointers (Part 3 register map)
 PTR_PORTB      EQU 0x00       ; read:  1 byte, RB5:RB0
 PTR_DISPLAY    EQU 0x01       ; write: 1 byte, 7-bit ASCII
 PTR_ADC        EQU 0x02       ; read:  2 bytes, high then low
 PTR_STATUS     EQU 0x04       ; read:  1 byte, device status
 
; Status byte (pointer 0x04). Bits 3:0 are sticky and clear when the status is read.
ST_SSPOV       EQU 0          ; MSSP receive overflow occurred
ST_WCOL        EQU 1          ; MSSP write collision occurred
ST_BADPTR      EQU 2          ; unsupported pointer, or read of write-only register
ST_BADLEN      EQU 3          ; unexpected data bytes (extra bytes, or data sent to a read-only register)
ST_ADCBUSY     EQU 4          ; live: conversion in progress
ST_ADCVALID    EQU 5          ; at least one conversion stored since reset
ST_STICKY_CLR  EQU 0xF0       ; AND mask that clears the sticky bits
ST_STICKY_MSK  EQU 0x0F
 
; Application flags (app_flags)
FLG_EXPECT_PTR   EQU 0        ; next received byte after an address-write is the pointer
FLG_IGNORE       EQU 1        ; pointer was bad: discard the data bytes of this write
FLG_DISP_PENDING EQU 2        ; a character is staged for the DLG7137
FLG_ADC_PENDING  EQU 3        ; a conversion was started and not yet stored
FLG_ADC_VALID    EQU 4        ; adc_hi/adc_lo hold a real conversion
 
; DLG7137 wiring (ASSUMED: edit to match your schematic)
;   D0-D2 -> RC0-RC2, D3 -> RA0, D4 -> RA1, D5-D6 -> RC5-RC6, /WR -> RC7
;   (D3/D4 moved to PORTA because RC3/RC4 are the I2C pins)
DISP_WR_BIT    EQU 7          ; PORTC bit, active low
DISP_MASK_C    EQU 0x67       ; char bits that map straight onto PORTC bits 6,5,2,1,0
DISP_D3_BIT    EQU 3          ; char bit 3 -> RA0
DISP_D4_BIT    EQU 4          ; char bit 4 -> RA1
 
; Timer1 runs 1 us per tick (1:1, Fosc/4). Interval = 65536 - preload, in us.
; 0xEC78 -> 65536 - 60536 = 5 ms ADC sample interval.
 RELOAD_H       EQU 0xEC
 RELOAD_L       EQU 0x78
 
; Bit numbers
BIT_TMR1ON     EQU 0          ; T1CON
BIT_TMR1IF     EQU 0          ; PIR1
BIT_SSPIF      EQU 3          ; PIR1
BIT_BF         EQU 0          ; SSPSTAT
BIT_RW         EQU 2          ; SSPSTAT (R/W: 1 = master is reading)
BIT_DA         EQU 5          ; SSPSTAT (D/A: 1 = last byte was data)
BIT_CKP        EQU 4          ; SSPCON
BIT_SSPOV      EQU 6          ; SSPCON
BIT_WCOL       EQU 7          ; SSPCON
BIT_ACKSTAT    EQU 6          ; SSPCON2 (1 = master NACKed)
BIT_GO         EQU 1          ; ADCON0 (GO/DONE)
BIT_RBPU       EQU 7          ; OPTION_REG (0 = PORTB pull-ups enabled)
Z_BIT          EQU 2          ; STATUS zero
 
; ======================================================================
; Variables (Bank 0)
; ======================================================================
PSECT udata_bank0
reg_ptr:       DS 1           ; selected register pointer (kept after STOP)
rx_byte:       DS 1           ; last byte received from the master
rx_count:      DS 1           ; data bytes received after the pointer in this write
tx_index:      DS 1           ; number of bytes already sent in this read
ev_stat:       DS 1           ; copy of SSPSTAT for the current event
ev_ack:        DS 1           ; copy of SSPCON2 for the current event
app_flags:     DS 1           ; FLG_* bits
dev_status:    DS 1           ; sticky status bits 3:0
disp_char:     DS 1           ; staged DLG7137 character (7-bit ASCII)
adc_hi:        DS 1           ; latest stored conversion, bits 9:8
adc_lo:        DS 1           ; latest stored conversion, bits 7:0
snap_hi:       DS 1           ; copy taken at the start of an ADC read so both bytes
snap_lo:       DS 1           ;   always come from the same conversion
dly_lo:        DS 1           ; stretch-delay counters
dly_hi:        DS 1
tmp:           DS 1           ; scratch
 
; ======================================================================
; Vectors
; ======================================================================
PSECT resetVect,class=CODE,delta=2
ResetVector:
    goto Setup
 
PSECT code,class=CODE,delta=2
 
; ======================================================================
; Setup
; ======================================================================
Setup:
    CLRF INTCON                 ; polled, no interrupts
 
    BANKSEL PORTA
    CLRF PORTA
    CLRF PORTB
    MOVLW 0x80
    MOVWF PORTC                 ; display /WR idles high, data lines low
    
    BANKSEL TRISA
    MOVLW 0xFC
    MOVWF TRISA                 ; RA1:RA0 outputs (display D4:D3), RA2 = AN2 input
    MOVLW 0xFF
    MOVWF TRISB                 ; RB5:RB0 switches, RB7:RB6 left for the PICkit
    MOVLW 0x18
    MOVWF TRISC                 ; RC3/RC4 = I2C, the rest display outputs
 
    BANKSEL OPTION_REG
    BCF OPTION_REG,BIT_RBPU     ; enable weak pull-ups on PORTB...
    MOVLW 0x3F
    MOVWF WPUB                  ; ...for RB5:RB0 only: open switch = 1, closed = 0
 
    BANKSEL ANSEL
    MOVLW ANSEL_VAL
    MOVWF ANSEL
    CLRF ANSELH                 ; RB5:RB0 digital
 
    BANKSEL ADCON1
    MOVLW ADCON1_VAL
    MOVWF ADCON1
    BANKSEL ADCON0
    MOVLW ADCON0_VAL
    MOVWF ADCON0
 
    BANKSEL SSPADD
    MOVLW SSPADD_VAL
    MOVWF SSPADD
    BANKSEL SSPSTAT
    MOVLW SSPSTAT_VAL
    MOVWF SSPSTAT
    BANKSEL SSPCON2
    MOVLW SSPCON2_VAL
    MOVWF SSPCON2
    BANKSEL SSPCON
    MOVLW SSPCON_VAL            ; enable MSSP last
    MOVWF SSPCON
 
    BANKSEL T1CON
    CLRF T1CON                  ; Timer1 off, 1:1, internal clock
 
    BANKSEL reg_ptr
    CLRF reg_ptr                ; power-up pointer = 0x00 (PORTB)
    CLRF rx_byte
    CLRF rx_count
    CLRF tx_index
    CLRF app_flags
    CLRF dev_status
    CLRF disp_char
    CLRF adc_hi
    CLRF adc_lo
    CLRF snap_hi
    CLRF snap_lo
    CALL ReloadTimer1           ; start the ADC sample interval
 
; ======================================================================
; Main: service I2C first, then run the application tasks
; ======================================================================
Main:
    CALL SlaveService           ; Level 1: handle at most one MSSP event
    CALL AppTasks               ; Level 3: display, ADC (short, non-blocking)
    goto Main
 
; ======================================================================
; Level 3: application (all routines enter and leave in Bank 0)
; ======================================================================
 
AppTasks:
    BTFSS app_flags,FLG_DISP_PENDING
    goto AppAdc
    BCF app_flags,FLG_DISP_PENDING
    CALL DisplayWrite           ; staged by the I2C handler, written here
AppAdc:
    BANKSEL PIR1
    BTFSS PIR1,BIT_TMR1IF
    goto AppAdcStore
    CALL ReloadTimer1           ; next sample interval
    BANKSEL ADCON0
    BTFSC ADCON0,BIT_GO
    goto AppAdcStore            ; previous conversion still running
    BSF ADCON0,BIT_GO           ; start a conversion; do not wait for it
    BSF app_flags,FLG_ADC_PENDING
AppAdcStore:
    BTFSS app_flags,FLG_ADC_PENDING
    RETURN
    BANKSEL ADCON0
    BTFSC ADCON0,BIT_GO
    RETURN                      ; still converting
    BCF app_flags,FLG_ADC_PENDING
    MOVF ADRESH,W
    MOVWF adc_hi                ; both bytes are stored in one pass of Main, so an
    BANKSEL ADRESL              ; I2C event can never see half of a new conversion
    MOVF ADRESL,W
    BANKSEL adc_lo
    MOVWF adc_lo
    BSF app_flags,FLG_ADC_VALID
    RETURN
 
; Put disp_char on the DLG7137 data lines and pulse /WR low
DisplayWrite:
    MOVF disp_char,W
    ANDLW DISP_MASK_C
    MOVWF tmp                   ; bits 6,5,2,1,0 go straight to RC6,RC5,RC2,RC1,RC0
    MOVF PORTC,W
    ANDLW 0x98                  ; keep RC7 (/WR) and RC4:RC3 (I2C pins) as they are
    IORWF tmp,W
    MOVWF PORTC
    BCF PORTA,0                 ; D3 -> RA0
    BTFSC disp_char,DISP_D3_BIT
    BSF PORTA,0
    BCF PORTA,1                 ; D4 -> RA1
    BTFSC disp_char,DISP_D4_BIT
    BSF PORTA,1
    BCF PORTC,DISP_WR_BIT       ; /WR low (check the DLG7137 data sheet for min pulse width)
    NOP
    NOP
    NOP
    NOP
    BSF PORTC,DISP_WR_BIT       ; /WR high latches the character
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
; Level 2: pointer, read and write transactions (no MSSP register access)
;   Called by Level 1 with Bank 0 selected.
; ======================================================================
 
; W = byte received from the master (pointer byte or data byte)
Slave_OnRxByte:
    MOVWF rx_byte
    MOVLW DIAG_MODE
    XORLW DIAG_FIXED
    BTFSC STATUS,Z_BIT
    RETURN                      ; Step 2 diagnostic: ACK and discard
    BTFSS app_flags,FLG_EXPECT_PTR
    goto RxData
 
    ; first byte after the address = register pointer
    BCF app_flags,FLG_EXPECT_PTR
    MOVLW DIAG_MODE
    XORLW DIAG_ECHO
    BTFSC STATUS,Z_BIT
    goto AcceptPtr              ; echo diagnostic accepts any value
    MOVF rx_byte,W
    XORLW PTR_PORTB
    BTFSC STATUS,Z_BIT
    goto AcceptPtr
    MOVF rx_byte,W
    XORLW PTR_DISPLAY
    BTFSC STATUS,Z_BIT
    goto AcceptPtr
    MOVF rx_byte,W
    XORLW PTR_ADC
    BTFSC STATUS,Z_BIT
    goto AcceptPtr
    MOVF rx_byte,W
    XORLW PTR_STATUS
    BTFSC STATUS,Z_BIT
    goto AcceptPtr
    ; unsupported pointer: ACKed by hardware, flagged, old pointer kept, data dropped
    BSF dev_status,ST_BADPTR
    BSF app_flags,FLG_IGNORE
    RETURN
AcceptPtr:
    MOVF rx_byte,W
    MOVWF reg_ptr               ; stays selected after STOP until the next pointer write
    RETURN
 
RxData:
    BTFSC app_flags,FLG_IGNORE
    RETURN                      ; following a bad pointer
    INCF rx_count,F
    MOVF reg_ptr,W
    XORLW PTR_DISPLAY
    BTFSS STATUS,Z_BIT
    goto RxBadLen               ; read-only register: data not allowed
    MOVF rx_count,W
    XORLW 1
    BTFSS STATUS,Z_BIT
    goto RxBadLen               ; display takes exactly one data byte
    MOVF rx_byte,W
    ANDLW 0x7F                  ; 7-bit ASCII
    MOVWF disp_char
    BSF app_flags,FLG_DISP_PENDING  ; DisplayWrite runs from Main, not here
    RETURN
RxBadLen:
    BSF dev_status,ST_BADLEN
    RETURN
 
; Returns W = next byte for the master. tx_index counts bytes already sent
; in this read (cleared at the address match). Bytes past the end return 0xFF.
Slave_NextTxByte:
    MOVF tx_index,W
    MOVWF tmp                   ; tmp = index of the byte being sent
    INCF tx_index,F
    MOVLW DIAG_MODE
    XORLW DIAG_FIXED
    BTFSS STATUS,Z_BIT
    goto TxNotFixed
    MOVLW FIXED_BYTE
    RETURN
TxNotFixed:
    MOVLW DIAG_MODE
    XORLW DIAG_ECHO
    BTFSS STATUS,Z_BIT
    goto TxMap
    MOVF reg_ptr,W              ; echo diagnostic: return the selected pointer
    RETURN
TxMap:
    MOVF reg_ptr,W
    XORLW PTR_PORTB
    BTFSC STATUS,Z_BIT
    goto TxPortB
    MOVF reg_ptr,W
    XORLW PTR_ADC
    BTFSC STATUS,Z_BIT
    goto TxAdc
    MOVF reg_ptr,W
    XORLW PTR_STATUS
    BTFSC STATUS,Z_BIT
    goto TxStatus
    BSF dev_status,ST_BADPTR    ; pointer 0x01 is write-only
TxFiller:
    MOVLW 0xFF
    RETURN
 
TxPortB:
    MOVF tmp,F
    BTFSS STATUS,Z_BIT
    goto TxFiller               ; only one byte defined
    CALL StretchDelay           ; Step 4 experiment: SCL is still held LOW by the MSSP here
    MOVF PORTB,W
    ANDLW 0x3F                  ; RB5:RB0 only
    RETURN
 
TxAdc:
    MOVF tmp,F
    BTFSS STATUS,Z_BIT
    goto TxAdcLow
    MOVF adc_hi,W               ; first byte: copy both bytes of the current conversion
    MOVWF snap_hi
    MOVF adc_lo,W
    MOVWF snap_lo
    MOVF snap_hi,W
    RETURN
TxAdcLow:
    MOVF tmp,W
    XORLW 1
    BTFSS STATUS,Z_BIT
    goto TxFiller
    MOVF snap_lo,W              ; second byte comes from the same copy
    RETURN
 
TxStatus:
    MOVF tmp,F
    BTFSS STATUS,Z_BIT
    goto TxFiller
    MOVF dev_status,W
    ANDLW ST_STICKY_MSK
    MOVWF tmp                   ; sticky bits
    BTFSC ADCON0,BIT_GO
    BSF tmp,ST_ADCBUSY          ; live bits
    BTFSC app_flags,FLG_ADC_VALID
    BSF tmp,ST_ADCVALID
    MOVLW ST_STICKY_CLR
    ANDWF dev_status,F          ; sticky bits clear once they have been reported
    MOVF tmp,W
    RETURN
 
; Software delay of about 3 us * (STRETCH_H:STRETCH_L); skipped when 0
StretchDelay:
    MOVLW STRETCH_H
    MOVWF dly_hi
    MOVLW STRETCH_L
    MOVWF dly_lo
    MOVF dly_lo,F
    BTFSS STATUS,Z_BIT
    INCF dly_hi,F               ; standard 16-bit loop adjustment
    MOVF dly_hi,F
    BTFSC STATUS,Z_BIT
    RETURN                      ; count was 0: no extra delay
DlyLoop:
    DECFSZ dly_lo,F
    goto DlyLoop
    DECFSZ dly_hi,F
    goto DlyLoop
    RETURN
 
; ======================================================================
; Level 1: MSSP hardware events (7-bit slave, polled SSPIF)
;   Knows nothing about registers; calls Level 2 hooks.
; ======================================================================
 
; Handle one MSSP event if SSPIF is set (Bank 0 on entry and exit)
SlaveService:
    BANKSEL PIR1
    BTFSS PIR1,BIT_SSPIF
    RETURN                      ; no event
    BCF PIR1,BIT_SSPIF
 
    BTFSS SSPCON,BIT_SSPOV      ; receive overflow: a byte was lost
    goto SvcChkWcol
    BSF dev_status,ST_SSPOV
    BCF SSPCON,BIT_SSPOV        ; software must clear it (SSPBUF is read below)
SvcChkWcol:
    BTFSS SSPCON,BIT_WCOL       ; write collision: SSPBUF written while busy
    goto SvcClassify
    BSF dev_status,ST_WCOL
    BCF SSPCON,BIT_WCOL
SvcClassify:
    BANKSEL SSPSTAT
    MOVF SSPSTAT,W
    BANKSEL ev_stat
    MOVWF ev_stat               ; work from a copy of D/A and R/W
    BTFSS ev_stat,BIT_DA
    goto EvAddress              ; D/A = 0: address byte
    BTFSC ev_stat,BIT_RW
    goto EvTxData               ; D/A = 1, R/W = 1: master is reading
    ; D/A = 1, R/W = 0: data byte written by the master
EvRxData:
    MOVF SSPBUF,W               ; reading SSPBUF clears BF
    goto Slave_OnRxByte         ; tail call
 
; Our address matched. SCL is held LOW by hardware for a read until CKP is set.
EvAddress:
    MOVF SSPBUF,W               ; discard the address byte, clears BF
    CLRF rx_count               ; new transaction: restart byte counters
    CLRF tx_index
    BTFSC ev_stat,BIT_RW
    goto SendNextByte           ; master read: supply the first byte
    BSF app_flags,FLG_EXPECT_PTR
    BCF app_flags,FLG_IGNORE
    RETURN
 
; A byte we sent was clocked out; the master's ACK/NACK is now valid
EvTxData:
    BANKSEL SSPCON2
    MOVF SSPCON2,W
    BANKSEL ev_ack
    MOVWF ev_ack
    BTFSS ev_ack,BIT_ACKSTAT
    goto SendNextByte           ; master ACKed: it wants another byte
    BSF SSPCON,BIT_CKP          ; master NACKed: transfer over, make sure SCL is free
    RETURN
 
; Ask Level 2 for a byte, load it, and release SCL
SendNextByte:
    CALL Slave_NextTxByte       ; W = byte (Bank 0 on return)
    MOVWF SSPBUF
    BSF SSPCON,BIT_CKP          ; release SCL: the master can now clock the byte out
    RETURN
 
End