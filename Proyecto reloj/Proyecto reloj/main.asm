;******************************************************************************
; Universidad del Valle de Guatemala 
; 1E2023: Programacion de Microcontroladores 
; main.asm 
; Autor: Jacob Tabush 
; Proyecto: Proyecto PdM
; Hardware: ATMEGA328P 
; Creado: 21/02/2024 
; Ultima modificacion: 6/03/2024 
;*******************************************************************************

.include "M328PDEF.inc"

; dejamos a R16 a R18 para uso general 

.def outerloop=R19

.def timeseg=R20 ; reservamos un register para el contador de los segundos, usaremos los primeros 4 bits para el primer digito y los segundo 4 bits para el segundo digito
.def timemin=R21 ;  reservamos un register para el contador de los minutos, misma config que los segundos
.def timehr=R22 ; reservamos un register para el contador de las horas, misma config que los primeros 2

.def alarmseg=R23 ; alarma segundos, 0-3 ones, 4-6 tens
.def alarmmin=R24 ; alarma minutos, 0-3 ones, 4-6 tens
.def alarmhr=R25 ; alarma horas, 0-3 ones, 4-5 tens

.def day=R26
.def month=R27

.def muxshow=R28 ; reservamos un register para determinar que mostrar en el mux
.def debounceactive=R29 ; reservamos un register para el estado del debounce
.def debouncetimer=R30 ; reservamos un register para el timer del debounce

.def state=R31 ; estado de la maquina. Bits 0 - 1 corresponden a desplegar el tiempo, alarma y fecha. Bit 2 se activa cuando se esta cambiando el dado valor, y 4 cuando la alarma se activa
; utilizamos bits 5-8 para los estados de los botones

.equ oltlength = 250 ; outer loop time length

.equ timr2reset = 194

.cseg
.org 0x00
JMP MAIN ; vector reset

.org 0x0008 ; Vector de ISR: PCINT1
	JMP ISR_PCINT1

	.org 0x0012
	JMP ISR_TIMR2

	.org 0x0020 ; Vector de ISR: Timer 0 overflow
	JMP ISR_TIMR0


MAIN:
; STACK POINTER

LDI R16, LOW(RAMEND)
OUT SPL, R16
LDI R17, HIGH(RAMEND)
OUT SPH, R17

; nuestra tabla de valores del 7 seg, con pin0 = a, pin1 = b...
tabla7seg: .DB  0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x67, 0x77, 0x7C, 0x58, 0x5E, 0x79, 0x71

; nuestra tabla que contiene que tan largo es cada mes
monthlengths: .DB 0x1F, 0x1C, 0x1F, 0x1E, 0x1F, 0x1E, 0x1F, 0x1F, 0x1E, 0x1F, 0x1E, 0x1F

; ///////////////////////////////////////////////////////
; Configuracion
; ///////////////////////////////////////////////////////

Setup:

;  prescaler

LDI R16, 0b1000_0000
STS CLKPR, R16

LDI R16, 0b0000_0011 ;1 MHz
STS CLKPR, R16 

; utilizamos D para controlar el disp de 7 segmentos
LDI R16, 0xFF
OUT DDRD, R16 ;Ponemos a todo D como salidas
LDI R16, 0x00
OUT PORTD, R16 ; Apagamos todas las salidas

; Utilizamos C para los botones
LDI R16, 0b0000_0000
OUT DDRC, R16 ; Ponemos a todo C como entradas 
LDI R16, 0x00
OUT PORTC, R16 ; Apagamos todas estas

; Utilizamos B para mux de los displays y la alarma
LDI R16, 0b0001_1111
OUT DDRB, R16 
LDI R16, 0b0000_0000
OUT PORTB, R16 

; Habilitamos pin change interrupt en PC0-PC2
LDI R16, 0x02
STS PCICR, R16
LDI R16, 0x03
STS PCMSK1, R16

; Habilitamos un interrupt en timr0 y timr2 overflow
LDI R16, 0x01
STS TIMSK0, R16
STS TIMSK2, R16

LDI R16, 0x00
STS UCSR0B, R16 ; deshablitamos el serial en pd0 y pd1

timer0init: ; utilizaremos el timer 0 para todo el toma de tiempo principal del doc (como el 

LDI R16, (1 << CS02) | (1 << CS00)
OUT TCCR0B, R16 ; prescaler de 1024

LDI R16, 235 ; Cargamos 235 al contador = aproximadamente 10ms
OUT TCNT0, R16

timer2init: 
LDI R16, 0b0000_0010 
STS TCCR2B, R16 ; prescaler 8

LDI R16, timr2reset
STS TCNT2, R16



LDI timeseg, 0x00
LDI timemin, 0x00
LDI timehr, 0x00
LDI alarmseg, 0x00
LDI alarmmin, 0x00
LDI alarmhr, 0x00

LDI muxshow, 0x01 ; Este nos permitira utilizar el comando swap para negar y denegar el primer bit
SEI ; habilitamos interrupts 

; ////////////////////////////////////////////////////////////////////

 
 ; //////////////////////////////////////////////
 ; Loop prmario
 ; //////////////////////////////////////////////

 Loop:

MOV R17, state
ANDI R17, 0b0000_0111

LDI R16, 0x00
CPSE R17, R16
RJMP checkifhoursstate
RJMP Displaysecondsmode

checkifhoursstate:
LDI R16, 0b0000_0001
CPSE R17, R16
RJMP Loop
RJMP Displayhoursmode


 Displaysecondsmode:

// SBRC state, 0
 //RJMP displayhoursmode

 SBRC state, 7
 CALL timecheck

LDI ZL, LOW(tabla7seg << 1) ; Seleccionamos el ZL para encontrar al bit bajo en el flash
LDI ZH, HIGH(tabla7seg << 1) ; Seleccionamos el ZH para ecnontar al bit alto en el flash

SBRS muxshow, 0 ; revisamos el valor del primer bit en muxshow pare determinar si desplegamos segundos
RJMP dsm2
LDI R16, 0x08
OUT PORTB, R16 ; encendemos el mux correcto
MOV R17, timeseg
ANDI R17, 0x0F

dsm2: ; desplego decenas de segundos
SBRS muxshow, 1 ; revisamos el valor del primer bit en muxshow pare determinar si desplegamos decenas
RJMP dsm3
LDI R16, 0x04
OUT PORTB, R16 ; encendemos el mux correcto
MOV R17, timeseg
SWAP R17
ANDI R17, 0x0F

dsm3: ; desplego minutos
SBRS muxshow, 2 ; revisamos el valor del primer bit en muxshow pare determinar si desplegamos minutos
RJMP dsm4
LDI R16, 0x02
OUT PORTB, R16 ; encendemos el mux correcto
MOV R17, timemin
ANDI R17, 0x0F

dsm4: ; desplego decenas de minutos
SBRS muxshow, 3 ; revisamos el valor del primer bit en muxshow pare determinar si desplegamos decenas de minutos
RJMP dsm5
LDI R16, 0x01
OUT PORTB, R16 ; encendemos el mux correcto
MOV R17, timemin
SWAP R17
ANDI R17, 0x0F

dsm5:

ADD ZL, R17 ; Le agreagamos el valor determinado, para ir al valor especifico de la tabla
LPM R16, Z ; Cargamos el valor del tabla a R16
OUT PORTD, R16 ; Cargar el valor a PORTD



RJMP Loop 

Displayhoursmode:
RJMP loop

/*


 SBRC state, 0
 RJMP displayhoursmode
 CBR state, 0b0000_0001

 SBRC state, 7
 CALL timecheck

LDI ZL, LOW(tabla7seg << 1) ; Seleccionamos el ZL para encontrar al bit bajo en el flash
LDI ZH, HIGH(tabla7seg << 1) ; Seleccionamos el ZH para ecnontar al bit alto en el flash

SBRS muxshow, 0 ; revisamos el valor del primer bit en muxshow pare determinar si desplegamos segundos
RJMP dsm2
LDI R16, 0x08
OUT PORTB, R16 ; encendemos el mux correcto
MOV R17, timeseg
ANDI R17, 0x0F

dsm2: ; desplego decenas de segundos
SBRS muxshow, 1 ; revisamos el valor del primer bit en muxshow pare determinar si desplegamos decenas
RJMP dsm3
LDI R16, 0x04
OUT PORTB, R16 ; encendemos el mux correcto
MOV R17, timeseg
SWAP R17
ANDI R17, 0x0F

dsm3: ; desplego minutos
SBRS muxshow, 2 ; revisamos el valor del primer bit en muxshow pare determinar si desplegamos minutos
RJMP dsm4
LDI R16, 0x02
OUT PORTB, R16 ; encendemos el mux correcto
MOV R17, timemin
ANDI R17, 0x0F

dsm4: ; desplego decenas de minutos
SBRS muxshow, 3 ; revisamos el valor del primer bit en muxshow pare determinar si desplegamos decenas de minutos
RJMP dsm5
LDI R16, 0x01
OUT PORTB, R16 ; encendemos el mux correcto
MOV R17, timemin
SWAP R17
ANDI R17, 0x0F

dsm5:

ADD ZL, R17 ; Le agreagamos el valor determinado, para ir al valor especifico de la tabla
LPM R16, Z ; Cargamos el valor del tabla a R16
OUT PORTD, R16 ; Cargar el valor a PORTD

RJMP Displaysecondsmode */

; ///////////////////////////////////
; Subrutina cambio de tiempo
; //////////////////////////////////

timecheck:
LDI state, 0x00

; revision segundos
INC timeseg ; Incrementamos el contador de segundos
LDI R16, 10
MOV R17, timeseg
ANDI R17, 0x0F ; solo queremos ver los segundos
CPSE R17, R16 ; revisamos que no haya superado 10
RETI ; Si no ha superado los 10 terminamos la interrupcion

; revision decenas
ANDI timeseg, 0xF0 ; colocamos a contador de segundos en 0
LDI R16, 0x10
ADD timeseg, R16 ; incrementamos el contador de decenas
LDI R16, 6 
MOV R17, timeseg
SWAP R17 ; colocamos decenas en los primeros 4 bits
ANDI R17, 0x0F 
CPSE R17, R16 ; revisamos que no haya superado 60
RETI ; Si no ha superado los 60 terminamos la interrupcion

; revision minutos
ANDI timeseg, 0x0F ; colocamos el contador de decenas de segundos en 0
INC timemin ; Incrementamos el contador de segundos
LDI R16, 10
MOV R17, timemin
ANDI R17, 0x0F ; solo queremos ver los minutos
CPSE R17, R16 ; revisamos que no haya superado 10
RETI ; Si no ha superado los 10 terminamos la interrupcion

; revision decenas de minutos
ANDI timemin, 0xF0 ; colocamos a contador de minutos en 0
LDI R16, 0x10
ADD timemin, R16 ; incrementamos el contador de decenas
LDI R16, 6 
MOV R17, timemin
SWAP R17 ; colocamos decenas en los primeros 4 bits
ANDI R17, 0x0F 
CPSE R17, R16 ; revisamos que no haya superado 60
RETI ; Si no ha superado los 60 terminamos la interrupcion

; revision horas
ANDI timemin, 0x0F ; colocamos el contador de decenas de segundos en 0
INC timehr ; Incrementamos el contador de segundos
MOV R17, timehr
ANDI R17, 0x0F ; solo queremos ver las horas

; check if 24
LDI R16, 4
CPSE R17, R16
RJMP reseton10hr
RJMP checkifnextday

reseton10hr:
LDI R16, 10
CPSE R17, R16 ; revisamos que no haya superado 10
RETI ; Si no ha superado los 10 terminamos la interrupcion

ANDI timehr, 0xF0 ; reseteamos el contador de hrs
LDI R16, 0x10
ADD timehr, R16 ; le sumamos 1 a las decenas
RETI

checkifnextday: ; solo ejecutar si horas (no decenas) = 4
LDI R16, 2 
MOV R17, timehr
SWAP R16
ANDI R17, 0x0F
CPSE R17, R16 ; revisamos si los decenas on iguales a 2
RJMP reseton10hr

ANDI timehr, 0x00
INC day 
RET


; ////////////////////////////////////////////////////
; Subrutinas de interrupcion
; ////////////////////////////////////////////////////

ISR_PCINT1: ; Para el cambio de pines

; debounce
/*
SBRC debounceactive, 0 ; revisamos si el debounce es activo, en caso que si no realizamos todo lo demas
RETI

incremento:
LDI debounceactive, 0x01 ; activamos el debouncer
LDI debouncetimer, 10 ; le colocamos 100ms al debouncetimer

SBIC PINB, PB0 ; analizamos PB0 primero y realizamos el incremento si esta en bajo
RJMP decremento 

INC counter
SBRC counter, 4 ; revisamos que no aumenta mas de los 4 bits
	LDI counter, 0x0F

decremento:
SBIC PINB, PB1 ; analizamos PB1 de segundo y realizamos el decremento si esta en bajo
RETI ; regresamo si ninguno de los pins esta set

DEC counter
SBRC counter, 7 ; revisamos que no hace wraparound para estar de mas de 4 bits
	LDI counter, 0x00

	*/
RETI


ISR_TIMR2:
LDI R16, timr2reset ; Cargamos 235 al contador = aproximadamente 10ms
STS TCNT2, R16

LSL muxshow
SBRC muxshow, 4
LDI muxshow, 0x01


SBI TIFR2, 0 ; Colocamos un 0 TV0 para reiniciar el timer
RETI



/// ISR TIMR y control de tiempo


ISR_TIMR0: ; Para el cambio de timer0

LDI R16, 235 ; Cargamos 235 al contador = aproximadamente 10ms
OUT TCNT0, R16

SBI TIFR0, 0 ; Colocamos un 0 TV0 para reiniciar el timer
SBRS debounceactive, 0 ; revisamos si el debounce esta activo
RJMP outerloopdecrease

DEC debouncetimer ; decrementamos el debounce timer cada 10ms
BRNE outerloopdecrease
LDI debounceactive, 0 ; desactivamos el protocolo de debounce

outerloopdecrease:
DEC outerloop
BRNE endtimr0

LDI outerloop, 100 ; le cargamos 100 al segundo loop 

LDI state, 0x80

endtimr0:
RETI


