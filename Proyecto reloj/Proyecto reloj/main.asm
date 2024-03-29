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

.def alarmmin=R23 ; alarma minutos, 0-3 ones, 4-6 tens
.def alarmhr=R24 ; alarma horas, 0-3 ones, 4-5 tens

.def day=R25  ; dia 
.def month=R26 ; mes

.def muxshow=R27 ; reservamos un register para determinar que mostrar en el mux
.def debouncetimer=R28 ; reservamos un register para el timer del debounce

.def state=R29 ; estado de la maquina. Bits 0 - 1 corresponden a desplegar el tiempo, alarma y fecha. 
;Bit 2 se activa cuando se esta cambiando el dado valor, y 3 cuando la alarma se activa
; utilizamos bits 4-5 para modos de editar
; y 6-7 para los estados de los botones

.equ timr1reset = 235 ; outer loop time length

.equ timr2reset = 25 ; muxeo time length

.equ debouncetime = 0xFF ; tiempo del debounce (multiplicar por timr2)

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
tabla7seg: .DB  0x40, 0x79, 0x24, 0x30, 0x19, 0x12, 0x02, 0x78, 0x00, 0x18, 0x08, 0x03, 0x27, 0x21, 0x06, 0x0E


; nuestra tabla que contiene que tan largo es cada mes
monthlengths: .DB 0x31, 0x28, 0x31, 0x30, 0x31, 0x30, 0x31, 0x31, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x31, 0x30, 0x31

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

; Utilizamos C para los botones, y alarma con indicador
LDI R16, 0b0000_1100
OUT DDRC, R16 
LDI R16, 0b0001_0011
OUT PORTC, R16 ; Encendemos pullups en 3 botones

; Utilizamos B para mux de los displays y la alarma
LDI R16, 0b0001_1111
OUT DDRB, R16 
LDI R16, 0b0000_0000
OUT PORTB, R16 

; Habilitamos pin change interrupt en PC0-PC2
LDI R16, 0x02
STS PCICR, R16
LDI R16, 0b0001_0011
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

LDI R16, timr1reset ; Cargamos 235 al contador = aproximadamente 10ms
OUT TCNT0, R16

timer2init: ; utilizamos el timer 2 para el muxeo y para debouncear los botones
LDI R16, 0b0000_0010 
STS TCCR2B, R16 ; prescaler 8

LDI R16, timr2reset
STS TCNT2, R16

LDI timeseg, 0x59
LDI timemin, 0x59
LDI timehr, 0x23
LDI alarmmin, 0x00
LDI alarmhr, 0x00
LDI month, 0x12
ldi day, 0x31

LDI muxshow, 0x01 ; Este nos permitira utilizar el comando swap para negar y denegar el primer bit
SEI ; habilitamos interrupts 

; ////////////////////////////////////////////////////////////////////

 
 ; //////////////////////////////////////////////
 ; Loop primario
 ; //////////////////////////////////////////////

 displayLoop: ; utilizamos este loop para controlar el modo de desplegue (no editar) y si desplegamos tiempo, fecha o alarma

 encenderluzdealarma:
 SBRC state, 3 ; revisamos si la alarma esta encendida
 SBI PORTC, PC2
 SBRS state, 3 
 CBI PORTC, PC2 ; apagamos el luz de alarma

 SBRS state, 5 ; revisamos si el boton 3 se encendio
 RJMP aftereditcheck
 CBR state, 0b0010_0000 ; apagamos el flag del boton
 SBR state, 0b0000_0100 ; encendemos el flag de editar

 aftereditcheck:
 SBRS state, 7 ; revisamos si el boton cambio de estado se activo
 RJMP afteradvancestate
 CBR state, 0b1000_0000 ; apagamos el flag del boton

 advancestate: ; utilizamos este bloque para avanzar al siguiente estado cuando se marca el boton cambio de estado
 MOV R17, state
ANDI R17, 0b0000_0011 ; solo queremos modificar los ultimos 2 bits - los de estado
INC R17
ANDI state, 0b1111_1100
ANDI R17, 0b0000_0011
OR state, R17

 afteradvancestate:
 SBRS state, 6 ; revisamos si el boton de decremento de estado se activo
 RJMP displayLoop2
 CBR state, 0b0100_0000 ; apagamos el flag del boton

 decreasestate:
 MOV R17, state
ANDI R17, 0b0000_0011 ; solo queremos modificar los ultimos 2 bits - los de estado
DEC R17
ANDI state, 0b1111_1100
ANDI R17, 0b0000_0011
OR state, R17

 


displayLoop2:

MOV R17, state
ANDI R17, 0b0000_0011

checkifsecondsstate: ; mostrar minutos y segundos
LDI R16, 0x00
CPSE R17, R16
RJMP checkifhoursstate
RJMP Displaysecondsmode

checkifhoursstate: ; mostrar horas y minutos
LDI R16, 0b0000_0001
CPSE R17, R16
RJMP checkifdatestate
RJMP Displayhoursmode

checkifdatestate: ; mostrar fecha
LDI R16, 0b0000_0010
CPSE R17, R16
RJMP checkifalarmstate
RJMP Displaydatemode

checkifalarmstate: ; mostrar alarma
LDI R16, 0b0000_0011
CPSE R17, R16
RJMP displayLoop
RJMP Displayalarmmode


; Cuando estamos en modo desplegue, utilizamos el siguiente serie de bloques para mostar valores en los displays 7

 Displaysecondsmode: 
 
 SBRS state, 2 ; revisamos si el bit de editar esta encendida
 RJMP Displaysecondsmode2

SBRS state, 3 ; revisamos si la bandera de alarma esta encendida
RJMP alarmoff
CBR state, 0b0000_1000 ; si esta encendida desactivamos la alarma
RJMP Displaysecondsmode2

alarmoff:
SBR state, 0b0000_1000 ; si esta apagado activamos la alarma

 Displaysecondsmode2:
 CBR state, 0b0000_0100 ; siempre desactivamos el flag de editar

 MOV R17, timeseg
 MOV R18, timemin
 CALL sevensegmentmux
 RJMP displayLoop

Displayhoursmode:

SBRC state, 2 ; si el registro de editar esta encendido saltamos al bloque respectivo
RJMP editTime 

 MOV R17, timemin
 MOV R18, timehr
  CALL sevensegmentmux
 RJMP displayLoop

 Displaydatemode:

 SBRC state, 2 ; si el registro de editar esta encendido saltamos al bloque respectivo
RJMP editDate

 MOV R17, month
 MOV R18, day
 CALL sevensegmentmux
 RJMP displayLoop

 Displayalarmmode:

 SBRC state, 2 ; si el registro de editar esta encendido saltamos al bloque respectivo
RJMP editAlarm

 MOV R17, alarmmin
 MOV R18, alarmhr
 CALL sevensegmentmux
 RJMP displayLoop



 ; ///////////////////////////
 ; Subrutina de muxeo y desplego en 7 segmentos
 ; ///////////////////////////

 sevensegmentmux: ; utilizamos este bloque para desplegar cosas en los 7 segment displays, cargamos el primer dato al R17 y el segundo a R18

LDI ZL, LOW(tabla7seg << 1) ; Seleccionamos el ZL para encontrar al bit bajo en el flash
LDI ZH, HIGH(tabla7seg << 1) ; Seleccionamos el ZH para ecnontar al bit alto en el flash

SBRS muxshow, 0 ; revisamos el valor del primer bit en muxshow pare determinar si desplegamos segundos
RJMP dsm2
LDI R16, 0x00
IN R16, PORTB
CBR R16, 0x0F
SBR R16, 0x08
OUT PORTB, R16 ; encendemos el mux correcto
ANDI R17, 0x0F

dsm2: ; desplego decenas de segundos
SBRS muxshow, 1 ; revisamos el valor del primer bit en muxshow pare determinar si desplegamos decenas
RJMP dsm3
LDI R16, 0x00
IN R16, PORTB
CBR R16, 0x0F
SBR R16, 0x04
OUT PORTB, R16 ; encendemos el mux correcto
SWAP R17
ANDI R17, 0x0F

dsm3: ; desplego minutos
SBRS muxshow, 2 ; revisamos el valor del primer bit en muxshow pare determinar si desplegamos minutos
RJMP dsm4
LDI R16, 0x00
IN R16, PORTB
CBR R16, 0x0F
SBR R16, 0x02
OUT PORTB, R16 ; encendemos el mux correcto
ANDI R18, 0x0F
MOV R17, R18

dsm4: ; desplego decenas de minutos
SBRS muxshow, 3 ; revisamos el valor del primer bit en muxshow pare determinar si desplegamos decenas de minutos
RJMP dsmend
LDI R16, 0x00
IN R16, PORTB
CBR R16, 0x0F
SBR R16, 0x01
OUT PORTB, R16 ; encendemos el mux correcto
SWAP R18
ANDI R18, 0x0F
MOV R17, R18

dsmend:

ADD ZL, R17 ; Le agreagamos el valor determinado, para ir al valor especifico de la tabla
LPM R16, Z ; Cargamos el valor del tabla a R16
OUT PORTD, R16 ; Cargar el valor a PORTD

RET

; //////////////////////////////////////
; Subrutina de editar tiempo
; //////////////////////////////////////


editTime: ; cambiar hroas
  CBR state, 0b0010_0000 

  CALL editTimeDisplay

  SBRC state, 5 ; si el boton 3 se apacha vamos al estado de cambiar minutos
  RJMP editTimemins

  SBRC state, 6 ; si el boton 1 se apacha vamos al estado de decrementar
  RJMP decreasehours

  SBRS state, 7 ; si el boton 2 se apacha incrementamos el tiempo por uno
  RJMP editTime

  //////////Bloque incrementar horas///////////////

  increasehours:

  CBR state, 0b1000_0000

  INC timehr ; Incrementamos el contador de horas
MOV R17, timehr
LDI R16, 0x24
CPSE R17, R16 ; revisamos si ha llegado a 24
RJMP editTimeHr2

LDI timehr, 0x00 ; si es igual a 24 lo reiniciamos
RJMP edittime

editTimeHr2:
ANDI R17, 0x0F ; solo queremos ver las horas
LDI R16, 10
CPSE R17, R16 ; revisamos que no haya superado 10
RJMP editTime ; Si no ha superado los 10 terminamos la interrupcion

ANDI timehr, 0xF0 ; reseteamos el contador de hrs
LDI R16, 0x10
ADD timehr, R16 ; le sumamos 1 a las decenas
RJMP editTime

  //////////Bloque decrementar horas///////////////

decreasehours:
CBR state, 0b0100_0000

LDI R16, 0x00 ; revisamos si es igual a 0 
CPSE timehr, R16
RJMP decreasehours2
LDI timehr, 0x23 ; le cargamos 23
RJMP editTime

decreasehours2:
DEC timehr
MOV R17, timehr
ANDI R17, 0x0F
LDI R16, 0x0F ; vamos a revisar si hubo underflow
CPSE R16, R17
RJMP editTime

CBR timehr, 0x0F ; cambiamos el valor del bit de unidades de 15 a 9
SBR timehr, 0x09
RJMP editTime

////////////////////////Modificacion minutos///////////////////////////////////

  editTimemins:

  CBR state, 0b0010_0000

  CALL editTimeDisplay

  SBRC state, 5 ; si el boton 3 se apacha terminamos
  RJMP editTimeEnd

  SBRC state, 6 ; si el boton 2 se apacha 
  RJMP decreaseMinutes

  SBRS state, 7 ; si el boton 1 se apacha incrementamos el tiempo por uno
  RJMP editTimemins

  //////////Bloque incrementar minutos///////////////

  increaseminutes:

  CBR state, 0b1000_0000

    INC timemin ; Incrementamos el contador de segundos
LDI R16, 10
MOV R17, timemin
ANDI R17, 0x0F ; solo queremos ver los segundos
CPSE R17, R16 ; revisamos que no haya superado 10
RJMP editTimemins ; Si no ha superado los 10 regresamos

; revision decenas
ANDI timemin, 0xF0 ; colocamos a contador de segundos en 0
LDI R16, 0x10
ADD timemin, R16 ; incrementamos el contador de decenas
LDI R16, 6 
MOV R17, timemin
SWAP R17 ; colocamos decenas en los primeros 4 bits
ANDI R17, 0x0F 
CPSE R17, R16 ; revisamos que no haya superado 60
RJMP editTimemins ; Si no ha superado los 60 terminamos la interrupcion
LDI timemin, 0x00 

RJMP editTimemins

//////////Bloque decrementar minutos///////////////

decreaseminutes:
CBR state, 0b0100_0000

LDI R16, 0x00
CPSE timemin, R16 ; revision 0->59
RJMP decreaseminutes2
LDI timemin, 0x59 ; le cargamos 59
RJMP editTimemins

decreaseminutes2:
DEC timemin
MOV R17, timemin
ANDI R17, 0x0F
LDI R16, 0x0F ; vamos a revisar si hubo underflow
CPSE R16, R17
RJMP editTimemins

CBR timemin, 0x0F ; cambiamos el valor del bit de unidades de 15 a 9
SBR timemin, 0x09
RJMP editTimemins



editTimeEnd:
  LDI timeseg, 0x00 ; reiniciamos segundos
  CBR state, 0b0010_0100 ; apagamos el flag de edit y el del boton

  RJMP displayLoop ; regresamos el modo display

editTimeDisplay:
MOV R17, timemin
 MOV R18, timehr
  CALL sevensegmentmux ; desplegamos el tiempo
  RET

  ; //////////////////////////////////////
; Subrutina de editar alarma (igual que cambiar tiempo
; //////////////////////////////////////


editalarm: ; cambiar hroas
  CBR state, 0b0010_0000 

  CALL editalarmDisplay

  SBRC state, 5 ; si el boton 3 se apacha vamos al estado de cambiar minutos
  RJMP editalarmmins

  SBRC state, 6 ; si el boton 1 se apacha vamos al estado de decrementar
  RJMP decreasehoursa

  SBRS state, 7 ; si el boton 2 se apacha incrementamos el tiempo por uno
  RJMP editalarm

  //////////Bloque incrementar horas///////////////

  increasehoursa:

  CBR state, 0b1000_0000

  INC alarmhr ; Incrementamos el contador de horas
MOV R17, alarmhr
LDI R16, 0x24
CPSE R17, R16 ; revisamos si ha llegado a 24
RJMP editalarmHr2

LDI alarmhr, 0x00 ; si es igual a 24 lo reiniciamos
RJMP editalarm

editalarmHr2:
ANDI R17, 0x0F ; solo queremos ver las horas
LDI R16, 10
CPSE R17, R16 ; revisamos que no haya superado 10
RJMP editalarm ; Si no ha superado los 10 terminamos la interrupcion

ANDI alarmhr, 0xF0 ; reseteamos el contador de hrs
LDI R16, 0x10
ADD alarmhr, R16 ; le sumamos 1 a las decenas
RJMP editalarm

  //////////Bloque decrementar horas///////////////

decreasehoursa:
CBR state, 0b0100_0000

LDI R16, 0x00 ; revisamos si es igual a 0 
CPSE alarmhr, R16
RJMP decreasehoursa2
LDI alarmhr, 0x23 ; le cargamos 23
RJMP editalarm

decreasehoursa2:
DEC alarmhr
MOV R17, alarmhr
ANDI R17, 0x0F
LDI R16, 0x0F ; vamos a revisar si hubo underflow
CPSE R16, R17
RJMP editalarm

CBR alarmhr, 0x0F ; cambiamos el valor del bit de unidades de 15 a 9
SBR alarmhr, 0x09
RJMP editalarm

////////////////////////Modificacion minutos///////////////////////////////////

  editalarmmins:

  CBR state, 0b0010_0000

  CALL editalarmDisplay

  SBRC state, 5 ; si el boton 3 se apacha terminamos
  RJMP editalarmEnd

  SBRC state, 6 ; si el boton 2 se apacha 
  RJMP decreaseminutesa

  SBRS state, 7 ; si el boton 1 se apacha incrementamos el tiempo por uno
  RJMP editalarmmins

  //////////Bloque incrementar minutos///////////////

  increaseminutesa:

  CBR state, 0b1000_0000

    INC alarmmin ; Incrementamos el contador de segundos
LDI R16, 10
MOV R17, alarmmin
ANDI R17, 0x0F ; solo queremos ver los segundos
CPSE R17, R16 ; revisamos que no haya superado 10
RJMP editalarmmins ; Si no ha superado los 10 regresamos

; revision decenas
ANDI alarmmin, 0xF0 ; colocamos a contador de segundos en 0
LDI R16, 0x10
ADD alarmmin, R16 ; incrementamos el contador de decenas
LDI R16, 6 
MOV R17, alarmmin
SWAP R17 ; colocamos decenas en los primeros 4 bits
ANDI R17, 0x0F 
CPSE R17, R16 ; revisamos que no haya superado 60
RJMP editalarmmins ; Si no ha superado los 60 terminamos la interrupcion
LDI alarmmin, 0x00 

RJMP editalarmmins

//////////Bloque decrementar minutos///////////////

decreaseminutesa:
CBR state, 0b0100_0000

LDI R16, 0x00
CPSE alarmmin, R16 ; revision 0->59
RJMP decreaseminutesa2
LDI alarmmin, 0x59 ; le cargamos 59
RJMP editalarmmins

decreaseminutesa2:
DEC alarmmin
MOV R17, alarmmin
ANDI R17, 0x0F
LDI R16, 0x0F ; vamos a revisar si hubo underflow
CPSE R16, R17
RJMP editalarmmins

CBR alarmmin, 0x0F ; cambiamos el valor del bit de unidades de 15 a 9
SBR alarmmin, 0x09
RJMP editalarmmins



editalarmEnd:
  CBR state, 0b0010_0100 ; apagamos el flag de edit y el del boton
  SBR state, 0b0000_1000 ; encendemos el bit de alarma

  RJMP displayLoop ; regresamos el modo display

editalarmDisplay:
MOV R17, alarmmin
 MOV R18, alarmhr
  CALL sevensegmentmux ; desplegamos la alarma
  RET

  ; //////////////////////////////////////
; Subrutina de editar fecha
; //////////////////////////////////////

  editDate: ; cambiar meses
  CBR state, 0b0010_0000 

  CALL editDateDisplay

  SBRC state, 5 ; si el boton 3 se apacha vamos al estado de cambiar dias
  RJMP editdayspre

  SBRC state, 6 ; si el boton 1 se apacha vamos al estado de decrementar
  RJMP decreasemonths

  SBRS state, 7 ; si el boton 2 se apacha incrementamos 
  RJMP editDate

  CBR state, 0b1000_0000 ; apagamos bandera boton incrementar

  incrementarmeses:
  INC month
LDI R16, 10
MOV R17, month
ANDI R17, 0x0F 
CPSE R17, R16 ; revisamos que no haya llegado a 10
RJMP checkoverflowyear

ANDI month, 0xF0 ; colocamos a contador de dias en 0
LDI R16, 0x10
ADD month, R16 ; incrementamos el contador de decenas de meses

checkoverflowyear:
LDI R16, 0x13
MOV R17, month
CPSE R17, R16 ; revisamos si es igual a 13
RJMP editDate
LDI month, 0x01 ; colocamos 1
RJMP editDate


decreasemonths:
CBR state, 0b0100_0000

DEC month
LDI R16, 0x0F
MOV R17, month
ANDI R17, 0x0F 
CPSE R17, R16 ; revisamos que unidades no haya bajado menor a 0 
RJMP checkunderflowyear

ANDI month, 0xF9 ; dejamos a unidades meses en 9  

checkunderflowyear:
LDI R16, 0x00
CPSE R16, month ; revisamos si estamos en 0 meses
RJMP editDate
LDI month, 0x12 ; cargamos 12
RJMP editDate



editdayspre:
LDI day, 0x01 ; reiniciamos el contador de dias
editDays:
CBR state, 0b0010_0000

CALL editDateDisplay

  SBRC state, 5 ; si el boton 3 se apacha vamos al estado de cambiar dias
  RJMP editdateend

  SBRC state, 6 ; si el boton 1 se apacha vamos al estado de decrementar
  RJMP decreasedays

  SBRS state, 7 ; si el boton 2 se apacha incrementamos 
  RJMP editDays

  increasedays:
  CBR state, 0b1000_0000 ; apagamos bandera boton incrementar

  INC day
LDI R16, 10
MOV R17, day
ANDI R17, 0x0F 
CPSE R17, R16 ; revisamos que no haya llegado a 10
RJMP checkoverflowday

ANDI day, 0xF0 ; colocamos a contador de dias en 0
LDI R16, 0x10
ADD day, R16 ; incrementamos el contador de decenas de dias

checkoverflowday:
LDI ZL, LOW(monthlengths << 1) ; Seleccionamos el ZL para encontrar al bit bajo en el flash
LDI ZH, HIGH(monthlengths << 1) ; Seleccionamos el ZH para ecnontar al bit alto en el flash
MOV R17, month
DEC R17
ADD ZL, R17
LPM R16, Z ; Cargamos el valor del tabla a R16
INC R16 ; le agregamos uno mas porque ahora el valor del dia es uno mas que el ultimo dia del mes

CPSE R16, day ; revisamos si ha llegado al maximo del dado mes
RJMP editDays
LDI day, 0x01 ; reiniciamos el contador de dias
RJMP editDays


decreasedays:
CBR state, 0b0100_0000

DEC day
LDI R16, 0x0F
MOV R17, day
ANDI R17, 0x0F 
CPSE R17, R16 ; revisamos que unidades no haya bajado menor a 0 
RJMP checkunderflowday

ANDI day, 0xF9 ; dejamos a unidades meses en 9  

checkunderflowday: 
LDI R16, 0x00
CPSE R16, day ; revisamos si estamos en 0 meses
RJMP editDays
LDI ZL, LOW(monthlengths << 1) ; Seleccionamos el ZL para encontrar al bit bajo en el flash
LDI ZH, HIGH(monthlengths << 1) ; Seleccionamos el ZH para ecnontar al bit alto en el flash
MOV R17, month
DEC R17
ADD ZL, R17
LPM day, Z ; Cargamos el valor del tabla a dias
RJMP editDays



editdateEnd:
  CBR state, 0b0010_0100 ; apagamos el flag de edit y el del boton
  RJMP displayLoop ; regresamos el modo display

  editdateDisplay:
MOV R18, day 
 MOV R17, month
  CALL sevensegmentmux ; desplegamos la fecha
  RET

; ///////////////////////////////////
; Subrutina cambio de tiempo
; //////////////////////////////////

timecheck:
CBR state, 0x80

; revisamos si el alarma esta activado
 SBRS state, 3
 RJMP afteralarmcheck

 LDI R17, 0x00
 CPSE timemin, alarmmin
 INC R17

 CPSE timehr, alarmhr
 INC R17

 LDI R16, 0x00
 CPSE R16, R17 
 RJMP afteralarmcheck
 SBI PORTC, PC3 ; encendemos la alarma
 
 afteralarmcheck:

; revision segundos
INC timeseg ; Incrementamos el contador de segundos
LDI R16, 10
MOV R17, timeseg
ANDI R17, 0x0F ; solo queremos ver los segundos
CPSE R17, R16 ; revisamos que no haya superado 10
RJMP timecheckend ; Si no ha superado los 10 terminamos la interrupcion

; revision decenas
ANDI timeseg, 0xF0 ; colocamos a contador de segundos en 0
LDI R16, 0x10
ADD timeseg, R16 ; incrementamos el contador de decenas
LDI R16, 6 
MOV R17, timeseg
SWAP R17 ; colocamos decenas en los primeros 4 bits
ANDI R17, 0x0F 
CPSE R17, R16 ; revisamos que no haya superado 60
RJMP timecheckend ; Si no ha superado los 60 terminamos la interrupcion

; revision minutos
ANDI timeseg, 0x0F ; colocamos el contador de decenas de segundos en 0
INC timemin ; Incrementamos el contador de segundos
LDI R16, 10
MOV R17, timemin
ANDI R17, 0x0F ; solo queremos ver los minutos
CPSE R17, R16 ; revisamos que no haya superado 10
RJMP timecheckend ; Si no ha superado los 10 terminamos la interrupcion

; revision decenas de minutos
ANDI timemin, 0xF0 ; colocamos a contador de minutos en 0
LDI R16, 0x10
ADD timemin, R16 ; incrementamos el contador de decenas
LDI R16, 6 
MOV R17, timemin
SWAP R17 ; colocamos decenas en los primeros 4 bits
ANDI R17, 0x0F 
CPSE R17, R16 ; revisamos que no haya superado 60
RJMP timecheckend ; Si no ha superado los 60 terminamos la interrupcion

; revision horas
ANDI timemin, 0x0F ; colocamos el contador de decenas de segundos en 0
INC timehr ; Incrementamos el contador de segundos
MOV R17, timehr
ANDI R17, 0x0F ; solo queremos ver las horas

reseton10hr:
LDI R16, 10
CPSE R17, R16 ; revisamos que no haya superado 10
RJMP checkifnextday ; Si no ha superado los 10 terminamos la interrupcion

ANDI timehr, 0xF0 ; reseteamos el contador de hrs
LDI R16, 0x10
ADD timehr, R16 ; le sumamos 1 a las decenas
RJMP timecheckend

; revision dias
checkifnextday: ; solo ejecutar si horas (no decenas) = 4
LDI R16, 0x24
MOV R17, timehr
CPSE R17, R16 ; revisamos si los decenas on iguales a 2
RJMP timecheckend
LDI timehr, 0x00
INC day

; revisamos si llegamos a decenas de dias
LDI R16, 10
MOV R17, day
ANDI R17, 0x0F
CPSE R17, R16
RJMP checkifnextmonth

ANDI day, 0xF0 ; colocamos a contador de dias en 0
LDI R16, 0x10
ADD day, R16 ; incrementamos el contador de decenas de dias

checkifnextmonth: ; utilizamos este bloque para cargar valores de los meses y despues revisar si el dia llega a esa cantidad
LDI ZL, LOW(monthlengths << 1) ; Seleccionamos el ZL para encontrar al bit bajo en el flash
LDI ZH, HIGH(monthlengths << 1) ; Seleccionamos el ZH para ecnontar al bit alto en el flash
MOV R17, month
DEC R17
ADD ZL, R17
LPM R16, Z ; Cargamos el valor del tabla a R16
INC R16 ; le agregamos uno mas porque ahora el valor del dia es uno mas que el ultimo dia del mes

CPSE R16, day ; revisamos si ha llegado al maximo del dado mes
RJMP timecheckend

; revision meses
LDI day, 0x01
INC month

LDI R16, 10
MOV R17, month
ANDI R17, 0x0F
CPSE R17, R16
RJMP checkifnextyear

ANDI month, 0xF0 ; colocamos a contador de dias en 0
LDI R16, 0x10
ADD month, R16 ; incrementamos el contador de decenas de meses

checkifnextyear:
LDI R16, 0x13
MOV R17, month
CPSE R17, R16 ; revisamos si los decenas on iguales a 2
RJMP timecheckend
LDI month, 0x01

timecheckend:
RET


; ////////////////////////////////////////////////////
; Subrutinas de interrupcion
; ////////////////////////////////////////////////////

ISR_PCINT1: ; Para el cambio de pines

; debounce
SBRC state, 4 ; revisamos si el debounce es activo, en caso que si no realizamos todo lo demas
RETI

SBIS PORTC, PC3 ; vemos si la alarma esta encendida
RJMP afterturningoffalarm
CBI PORTC, PC3 ; apagamos la alarma cuando cualquier boton se activa
CBR state, 0b0000_1000 ; tambien apagamos el flag de que la alarma esta encendida
RETI

afterturningoffalarm:
LDI debouncetimer, debouncetime 
SBR state, 0b0001_0000 ; marcamos que el debounce esta activo

SBIC PINC, PC0 
RJMP button2check

SBR state, 0b0100_0000 ; marcamos que se activo el primer boton 
RETI

button2check:
SBIC PINC, PC1
RJMP button3check
SBR state, 0b1000_0000 ; marcamos que se activo el segundo  boton 

button3check:
SBIC PINC, PC4
RETI
SBR state, 0b0010_0000 ; marcamos que se activo el tercer boton

RETI


ISR_TIMR2:
LDI R16, timr2reset ; Cargamos 0.1ms al timer2
STS TCNT2, R16

SBRS state, 4 ; revisamos si el debounce esta activo
RJMP afterdebouncecheck
DEC debouncetimer 
BRNE afterdebouncecheck
CBR state, 0b0001_0000 ; apagamos  el debounce

afterdebouncecheck:

; Control de muxeo de los 7 segment displays
LSL muxshow
SBRC muxshow, 4
LDI muxshow, 0x01

endtimr2:

SBI TIFR2, 0 ; Colocamos un 0 TV0 para reiniciar el timer
RETI



/// ISR TIMR y control de tiempo


ISR_TIMR0: ; Para el cambio de timer0

LDI R16, timr1reset ; Cargamos 10ms al timer0
OUT TCNT0, R16

SBRC state, 2 ; revisamos si estamos en modo de editar
RJMP edit750

MOV R16, state 
ANDI R16, 0x03 
CPI R16, 0x02 ; state de fecha
BREQ outerloopdecrease ; apagamos las luces si estamos en modo fecha

CPI R16, 0x03 ; state de alarma
BREQ outerloopdecrease ; queremos mantener la luz prendida en modo alarma

RJMP nonedit500

edit750: ; encender la luz en 750 ms si estamos en modo de editar
LDI R16, 75
CPSE outerloop, R16
RJMP edit500
SBI PORTC, PC5
RJMP edit500

nonedit500: ; encender la luz en 500ms si no estamos en modo de editar
LDI R16, 50 
CPSE outerloop, R16 ; revisamos si han pasado 500ms
RJMP outerloopdecrease
SBI PORTC, PC5 ; encendemos los luces de por medio
RJMP outerloopdecrease

edit500: ; apagar la luz en 500ms si estamos en modo editar
LDI R16, 50
CPSE outerloop, R16
RJMP edit250
CBI PORTC, PC5

edit250: ; modo editar - encender la luz en 250ms
LDI R16, 25
CPSE outerloop, R16
RJMP outerloopdecrease
SBI PORTC, PC5

outerloopdecrease:
DEC outerloop
BRNE endtimr0

MOV R16, state
ANDI R16, 0x03
CPI R16, 0x03 ; state de alarma
BREQ alarmstateactive ; queremos mantener la luz prendida en modo alarma

CBI PORTC, PC5 ; modo editar o normal - apagar la luz en 0ms
LDI outerloop, 100 ; le cargamos 100 al segundo loop 

SBRC state, 0b0000_0100 ; si el flag de editar esta encendido no activamos la subrutina cambio del tiempo
RJMP endtimr0
CALL timecheck ; rutina cambio de tiempo

endtimr0:
RETI

alarmstateactive:
SBI PORTC, PC5 ;siempre encendemos PC5 en caso que si

CALL timecheck
RETI