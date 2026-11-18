import { supabase } from './supabase'
import { filas, rpc } from './rpc'
import type { Categoria, Cuenta, Destino } from './finanzas'

export type TipoDeuda = 'por_cobrar' | 'por_pagar'
export type EstadoDeuda = 'pendiente' | 'parcial' | 'pagada' | 'anulada'
export type Deuda = {
  id: string
  tipo: TipoDeuda
  persona: string
  concepto: string | null
  monto_total: number
  destino_dinero: Destino
  categoria_id: string | null
  fecha_origen: string
  fecha_vencimiento: string | null
  origen: 'manual' | 'venta'
  movimiento_inicial_id: string | null
  pagado: number
  saldo: number
  estado: EstadoDeuda
}
export type PagoDeuda = { id: string; deuda_id: string; monto: number; fecha: string; anulado_at: string | null }
export type DatosDeudas = { deudas: Deuda[]; pagos: PagoDeuda[]; cuentas: Cuenta[]; categorias: Categoria[] }

/** Cuentas activas con saldo inicial registrado: las únicas que pueden recibir o entregar dinero. */
export const cuentasListas = () => filas<Cuenta>(
  supabase.from('finanzas_saldos_cuentas').select('*').eq('activa', true).not('saldo_inicial_definido_at', 'is', null).order('nombre'),
)

export async function cargarDeudas(): Promise<DatosDeudas> {
  const [deudas, pagos, cuentas, categorias] = await Promise.all([
    filas<Deuda>(supabase.from('deudas_resumen').select('*').order('fecha_creacion', { ascending: false }).limit(300)),
    filas<PagoDeuda>(supabase.from('deuda_pagos').select('id,deuda_id,monto,fecha,anulado_at').order('fecha_creacion', { ascending: false }).limit(1000)),
    cuentasListas(),
    filas<Categoria>(supabase.from('categorias').select('id,nombre,tipo,activa').eq('activa', true).order('nombre')),
  ])
  return { deudas, pagos, cuentas, categorias }
}

export type NuevaDeuda = {
  tipo: TipoDeuda; persona: string; concepto: string; monto: number; destino: Destino
  categoriaId: string | null; vencimiento: string | null; cuentaId: string | null
}

export const crearDeuda = (deuda: NuevaDeuda, operacionId: string) => rpc('deudas_crear', {
  p_tipo: deuda.tipo, p_persona: deuda.persona, p_concepto: deuda.concepto, p_monto: deuda.monto,
  p_destino: deuda.destino, p_categoria_id: deuda.categoriaId, p_fecha_vencimiento: deuda.vencimiento,
  p_cuenta_id: deuda.cuentaId, p_operacion_id: operacionId,
})

export const registrarPagoDeuda = (deudaId: string, monto: number, cuentaId: string, fecha: string, operacionId: string) =>
  rpc('deudas_registrar_pago', { p_deuda_id: deudaId, p_monto: monto, p_cuenta_id: cuentaId, p_fecha: fecha, p_operacion_id: operacionId })

export const anularPagoDeuda = (pagoId: string) =>
  rpc('deudas_anular_pago', { p_pago_id: pagoId, p_operacion_id: crypto.randomUUID() })

export const reprogramarDeuda = (deudaId: string, vencimiento: string | null) =>
  rpc('deudas_reprogramar', { p_deuda_id: deudaId, p_fecha_vencimiento: vencimiento })

export const anularDeuda = (deudaId: string) =>
  rpc('deudas_anular', { p_deuda_id: deudaId, p_operacion_id: crypto.randomUUID() })
