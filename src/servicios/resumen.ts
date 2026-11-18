import { supabase } from './supabase'
import { filas } from './rpc'
import { mesLima, sumarMeses } from './formato'
import type { Asignacion, Categoria, Cuenta, Movimiento } from './finanzas'
import type { Deuda } from './deudas'
import type { Producto } from './negocio'
import type { Pedido } from './apoyo'

export type FilaMensual = {
  mes: string; tipo: 'ingreso' | 'gasto'; origen: 'manual' | 'deuda' | 'compra' | 'venta'
  destino_dinero: string; categoria_id: string | null; total: number; cantidad: number
}
export type NegocioMensual = { mes: string; ventas: number; costo: number; ganancia: number; cantidad: number }

export type DatosInicio = {
  cuentas: Cuenta[]; asignaciones: Asignacion[]; mensual: FilaMensual[]; negocio: NegocioMensual[]
  deudas: Deuda[]; productos: Producto[]; pedidos: Pedido[]
}

export async function cargarInicio(): Promise<DatosInicio> {
  const desde = sumarMeses(mesLima(), -5)
  const [cuentas, asignaciones, mensual, negocio, deudas, productos, pedidos] = await Promise.all([
    filas<Cuenta>(supabase.from('finanzas_saldos_cuentas').select('*').order('nombre')),
    filas<Asignacion>(supabase.from('asignaciones_dinero').select('destino,monto')),
    filas<FilaMensual>(supabase.from('finanzas_resumen_mensual').select('*').gte('mes', desde)),
    filas<NegocioMensual>(supabase.from('negocio_resumen_mensual').select('mes,ventas,costo,ganancia,cantidad').gte('mes', desde)),
    filas<Deuda>(supabase.from('deudas_resumen').select('*').in('estado', ['pendiente', 'parcial'])),
    filas<Producto>(supabase.from('productos').select('id,nombre,precio_venta,costo_promedio,stock,stock_minimo,fecha_vencimiento,activo').eq('activo', true)),
    filas<Pedido>(supabase.from('pedidos').select('id,cliente,detalle,monto_estimado,fecha_entrega,estado,fecha_creacion').eq('estado', 'pendiente')),
  ])
  return { cuentas, asignaciones, mensual, negocio, deudas, productos, pedidos }
}

export type MovimientoReporte = Movimiento & { origen: FilaMensual['origen'] }
export type DatosReporte = {
  mensual: FilaMensual[]; anterior: FilaMensual[]; negocio: NegocioMensual | null
  movimientos: MovimientoReporte[]; categorias: Categoria[]; cuentas: Cuenta[]
}

/** Límites de un mes AAAA-MM en hora de Lima (UTC-5, sin horario de verano). */
const limitesMes = (mes: string) => [`${mes}-01T00:00:00-05:00`, `${sumarMeses(mes, 1)}-01T00:00:00-05:00`] as const

export async function cargarReporte(mes: string): Promise<DatosReporte> {
  const [inicio, fin] = limitesMes(mes)
  const [mensual, negocio, movimientos, categorias, cuentas] = await Promise.all([
    filas<FilaMensual>(supabase.from('finanzas_resumen_mensual').select('*').in('mes', [mes, sumarMeses(mes, -1)])),
    filas<NegocioMensual>(supabase.from('negocio_resumen_mensual').select('mes,ventas,costo,ganancia,cantidad').eq('mes', mes)),
    filas<MovimientoReporte>(supabase.from('movimientos')
      .select('id,cuenta_id,categoria_id,tipo,monto,descripcion,destino_dinero,direccion_transferencia,fecha_movimiento,anulado_at,anulado_motivo,origen')
      .gte('fecha_movimiento', inicio).lt('fecha_movimiento', fin).order('fecha_movimiento', { ascending: false }).limit(1000)),
    filas<Categoria>(supabase.from('categorias').select('id,nombre,tipo,activa')),
    filas<Cuenta>(supabase.from('finanzas_saldos_cuentas').select('*')),
  ])
  return {
    mensual: mensual.filter((fila) => fila.mes === mes),
    anterior: mensual.filter((fila) => fila.mes !== mes),
    negocio: negocio[0] ?? null, movimientos, categorias, cuentas,
  }
}

export const totalDe = (filasMes: FilaMensual[], tipo: 'ingreso' | 'gasto') =>
  filasMes.filter((fila) => fila.tipo === tipo).reduce((suma, fila) => suma + Number(fila.total), 0)

/** Nombre legible de dónde viene un ingreso o en qué se fue un gasto. */
export function fuenteDe(fila: { tipo: string; origen: string; categoria_id: string | null }, categorias: Categoria[]) {
  const categoria = categorias.find((item) => item.id === fila.categoria_id)?.nombre
  if (categoria) return categoria
  if (fila.origen === 'compra') return 'Compras de inventario'
  if (fila.origen === 'venta') return 'Ventas'
  if (fila.origen === 'deuda') return fila.tipo === 'ingreso' ? 'Cobros y préstamos recibidos' : 'Pagos y préstamos dados'
  return 'Sin categoría'
}
