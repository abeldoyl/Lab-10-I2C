    ; Abel Doyle
    ; RCET3375
    ; Lab10-1I2C
    ; https://github.com/abeldoyl/Lab-9-EEPROM/tree/main/Lab9-4EEPROM.X
    
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
SSPADD_VAL    EQU 9           ; SSPADD = 4 MHz / (4 * 100 kHz) - 1 = 9 -> SCL = 100 kHz
I2C_ADDR      EQU 0x20        ; 7-bit slave address
ADDR_BYTE     EQU 0x40        ; (0x20 << 1) | R/W = 0 -> byte put on the bus
 
SSPSTAT_VAL   EQU 0x80        ; SMP = 1: slew-rate control OFF (standard 100 kHz mode), CKE = 0
SSPCON_VAL    EQU 0x28        ; SSPEN = 1, SSPM = 1000: I2C master mode, clock = Fosc/(4*(SSPADD+1))
T1CON_VAL     EQU 0x01        ; TMR1ON = 1, 1:1 prescale, Fosc/4 -> 1 us per tick
 
; Bit numbers used below
BIT_TMR1IF    EQU 0           ; PIR1     Timer1 overflow flag
BIT_SSPIF     EQU 3           ; PIR1     MSSP event flag (START, STOP, or byte sent)
BIT_SEN       EQU 0           ; SSPCON2  START enable (1 = START in progress)
BIT_PEN       EQU 2           ; SSPCON2  STOP enable  (1 = STOP in progress)
BIT_ACKSTAT   EQU 6           ; SSPCON2  ACK status (0 = ACK received, 1 = NACK)
NACK_BIT      EQU 0           ; RA0 = NACK indicator
TIMER_BIT     EQU 1           ; RA1 = timer diagnostic (scope trigger)
SCL_BIT       EQU 3           ; RC3 = SCL
SDA_BIT       EQU 4           ; RC4 = SDA
 
; ======================================================================
; Vectors
; ======================================================================
PSECT resetVect,class=CODE,delta=2
ResetVector:
    goto Setup
 
PSECT code,class=CODE,delta=2
Setup:
    CLRF INTCON                 ; no interrupts used, everything is polled
 
    BANKSEL PORTA
    CLRF PORTA                  ; RA0 and RA1 start LOW
 
    BANKSEL TRISA
    BCF TRISA,NACK_BIT          ; RA0 = output (NACK indicator)
    BCF TRISA,TIMER_BIT         ; RA1 = output (timer diagnostic)
 
    BANKSEL TRISC
    BSF TRISC,SCL_BIT           ; RC3/SCL must be set as input; the MSSP drives it
    BSF TRISC,SDA_BIT           ; RC4/SDA must be set as input; the MSSP drives it
 
    BANKSEL ANSEL
    CLRF ANSEL                  ; all pins digital (RA0 and RA1 must not be analog)
    CLRF ANSELH
 
    BANKSEL SSPADD
    MOVLW SSPADD_VAL            ; baud rate: 100 kHz at 4 MHz
    MOVWF SSPADD
    BANKSEL SSPSTAT
    MOVLW SSPSTAT_VAL           ; standard speed, slew-rate control off
    MOVWF SSPSTAT
    BANKSEL SSPCON2
    CLRF SSPCON2                ; no START/STOP/ACK operations pending
    BANKSEL SSPCON
    MOVLW SSPCON_VAL            ; enable MSSP in I2C master mode (do this LAST)
    MOVWF SSPCON
 
    BANKSEL TMR1H               ; Timer1 free-runs from 0x0000
    CLRF TMR1H
    CLRF TMR1L
    BCF PIR1,BIT_TMR1IF         ; start with the overflow flag clear
    MOVLW T1CON_VAL             ; start Timer1: overflow every 65536 us = 65.536 ms
    MOVWF T1CON                 ; (T1CON is in Bank 0, so we finish in Bank 0)
 
; ----------------------------------------------------------------------
; Main waits for the Timer1 overflow flag, then:
;   RA1 HIGH -> AddressProbe (one full I2C transaction) -> RA1 LOW
; RA1 rises before START and falls after STOP, so it frames each
; transaction and gives the oscilloscope a trigger.
; AddressProbe returns with Bank 0 selected.
; ----------------------------------------------------------------------
Main:
    BTFSS PIR1,BIT_TMR1IF       ; Timer1 overflowed?
    goto Main                   ; no: keep waiting
    BCF PIR1,BIT_TMR1IF         ; clear the event flag
    BSF PORTA,TIMER_BIT         ; RA1 HIGH: transaction starting
    CALL AddressProbe
    BCF PORTA,TIMER_BIT         ; RA1 LOW: STOP is done
    goto Main
 
; ----------------------------------------------------------------------
; One address-only write transaction with no slave connected.
;   1. Clear the NACK indicator (RA0).
;   2. START   - set SEN, wait until the hardware clears it.
;   3. ADDRESS - write 0x40 to SSPBUF, wait for SSPIF (9th clock done).
;   4. ACKSTAT - 0 = ACK (leave RA0 LOW), 1 = NACK (set RA0 HIGH).
;   5. STOP    - set PEN, wait until the hardware clears it.
; With no slave nothing pulls SDA low on the 9th clock, so the
; result is always NACK. STOP is sent either way.
; ----------------------------------------------------------------------
AddressProbe:
    BANKSEL PORTA
    BCF PORTA,NACK_BIT          ; RA0 LOW at the start of each probe
 
    BANKSEL SSPCON2
    BSF SSPCON2,BIT_SEN         ; generate START
Probe_WaitStart:
    BTFSC SSPCON2,BIT_SEN       ; SEN clears when START is finished
    goto Probe_WaitStart
 
    BANKSEL PIR1
    BCF PIR1,BIT_SSPIF          ; clear the flag START left set
    MOVLW ADDR_BYTE             ; 0x40 = address 0x20 + R/W = 0
    MOVWF SSPBUF                ; writing SSPBUF starts the 9 clock pulses
Probe_WaitSend:
    BTFSS PIR1,BIT_SSPIF        ; SSPIF sets after the 9th clock
    goto Probe_WaitSend
    BCF PIR1,BIT_SSPIF
 
    BANKSEL SSPCON2
    BTFSS SSPCON2,BIT_ACKSTAT   ; ACKSTAT = 1 means NACK
    goto Probe_Stop             ; ACK: leave RA0 LOW
    BANKSEL PORTA
    BSF PORTA,NACK_BIT          ; NACK: RA0 HIGH
 
Probe_Stop:
    BANKSEL SSPCON2
    BSF SSPCON2,BIT_PEN         ; generate STOP
Probe_WaitStop:
    BTFSC SSPCON2,BIT_PEN       ; PEN clears when STOP is finished
    goto Probe_WaitStop
 
    BANKSEL PORTA               ; return in Bank 0 for Main
    RETURN
 
End