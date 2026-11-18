const formatoSoles = new Intl.NumberFormat('es-PE', { style: 'currency', currency: 'PEN' })

export const soles = (valor: number) => formatoSoles.format(Number(valor) || 0)
export const etiqueta = (valor: string) => valor.replaceAll('_', ' ').replace(/^./, (letra) => letra.toUpperCase())

/** Fecha de hoy en Lima con formato AAAA-MM-DD (valor de un input type="date"). */
export function hoyLima() {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Lima' }).format(new Date())
}

/** Mes actual en Lima con formato AAAA-MM. */
export const mesLima = () => hoyLima().slice(0, 7)

/** Suma (o resta) meses a un mes AAAA-MM. */
export function sumarMeses(mes: string, cantidad: number) {
  const [anio, numero] = mes.split('-').map(Number)
  const fecha = new Date(Date.UTC(anio, numero - 1 + cantidad, 1))
  return `${fecha.getUTCFullYear()}-${String(fecha.getUTCMonth() + 1).padStart(2, '0')}`
}

export function nombreMes(mes: string, largo = false) {
  const [anio, numero] = mes.split('-').map(Number)
  const texto = new Intl.DateTimeFormat('es-PE', { month: largo ? 'long' : 'short', timeZone: 'UTC' }).format(new Date(Date.UTC(anio, numero - 1, 1)))
  return largo ? `${texto} ${anio}` : texto.replace('.', '')
}

/** Muestra una fecha AAAA-MM-DD (o una marca de tiempo) como "05 nov". */
export function fechaCorta(valor: string | null) {
  if (!valor) return ''
  const fecha = valor.length === 10 ? new Date(`${valor}T12:00:00-05:00`) : new Date(valor)
  return fecha.toLocaleDateString('es-PE', { day: '2-digit', month: 'short', timeZone: 'America/Lima' })
}

/** Días desde hoy (Lima) hasta una fecha AAAA-MM-DD; negativo si ya pasó. */
export function diasHasta(fecha: string) {
  const dia = (texto: string) => Date.UTC(Number(texto.slice(0, 4)), Number(texto.slice(5, 7)) - 1, Number(texto.slice(8, 10)))
  return Math.round((dia(fecha) - dia(hoyLima())) / 86_400_000)
}

/** Convierte texto en un monto con hasta dos decimales, o null si no es válido. */
export function montoValido(valor: string, permiteCero = false): number | null {
  const limpio = valor.trim().replace(',', '.')
  if (!/^\d+(?:\.\d{1,2})?$/.test(limpio)) return null
  const numero = Number(limpio)
  return Number.isFinite(numero) && (permiteCero ? numero >= 0 : numero > 0) ? numero : null
}

export function enteroValido(valor: string, permiteCero = false): number | null {
  if (!/^\d+$/.test(valor.trim())) return null
  const numero = Number(valor)
  return Number.isSafeInteger(numero) && (permiteCero || numero > 0) ? numero : null
}

type Celda = string | number | null | undefined

/** Descarga un CSV que Excel abre directamente (UTF-8 con BOM). */
export function descargarCsv(nombre: string, encabezados: string[], filasCsv: Celda[][]) {
  const celda = (valor: Celda) => {
    let texto = valor === null || valor === undefined ? '' : String(valor)
    // Evita que Excel interprete como fórmula un texto escrito por la persona.
    if (typeof valor === 'string' && /^[=+\-@\t\r]/.test(texto)) texto = `'${texto}`
    return /[",\n\r]/.test(texto) ? `"${texto.replaceAll('"', '""')}"` : texto
  }
  const contenido = [encabezados, ...filasCsv].map((fila) => fila.map(celda).join(',')).join('\r\n')
  const url = URL.createObjectURL(new Blob(['﻿', contenido], { type: 'text/csv;charset=utf-8' }))
  const enlace = document.createElement('a')
  enlace.href = url
  enlace.download = `${nombre}.csv`
  enlace.click()
  URL.revokeObjectURL(url)
}
