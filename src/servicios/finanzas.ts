import { supabase } from './supabase'

export type Destino = 'personal' | 'negocio' | 'ahorros'
export type TipoCuenta = 'banco' | 'billetera_digital' | 'efectivo' | 'otro'
export type Cuenta = {
  id: string
  usuario_id: string
  nombre: string
  tipo: TipoCuenta
  codigo: string | null
  activa: boolean
  saldo_inicial_definido_at: string | null
  saldo_inicial_monto: number | null
  saldo: number
}
export type Asignacion = { destino: Destino; monto: number }
export type Movimiento = {
  id: string
  cuenta_id: string
  tipo: 'saldo_inicial' | 'ingreso' | 'gasto' | 'transferencia'
  monto: number
  descripcion: string | null
  destino_dinero: Destino | null
  direccion_transferencia: 'entrada' | 'salida' | null
  fecha_movimiento: string
}
export type Historial = {
  id: string
  tipo: string
  origen: Destino | null
  destino: Destino | null
  monto: number
  descripcion: string | null
  fecha_creacion: string
}
export type Categoria = { id: string; nombre: string; tipo: 'ingreso' | 'gasto' }
export type DatosFinanzas = {
  cuentas: Cuenta[]
  asignaciones: Asignacion[]
  movimientos: Movimiento[]
  historial: Historial[]
  categorias: Categoria[]
}

export class ModuloNoDisponible extends Error {}

export async function cargarFinanzas(usuarioId: string): Promise<DatosFinanzas> {
  const [cuentas, asignaciones, movimientos, historial, categorias] = await Promise.all([
    supabase.from('finanzas_saldos_cuentas').select('*').eq('usuario_id', usuarioId).order('nombre'),
    supabase.from('asignaciones_dinero').select('destino,monto').eq('usuario_id', usuarioId),
    supabase.from('movimientos').select('id,cuenta_id,tipo,monto,descripcion,destino_dinero,direccion_transferencia,fecha_movimiento').eq('usuario_id', usuarioId).order('fecha_movimiento', { ascending: false }).limit(30),
    supabase.from('historial_asignaciones').select('id,tipo,origen,destino,monto,descripcion,fecha_creacion').eq('usuario_id', usuarioId).order('fecha_creacion', { ascending: false }).limit(30),
    supabase.from('categorias').select('id,nombre,tipo').eq('usuario_id', usuarioId).eq('activa', true).order('nombre'),
  ])
  if (cuentas.error?.code === 'PGRST205' || cuentas.error?.code === '42P01') {
    throw new ModuloNoDisponible('La migración de Finanzas aún no está aplicada en este proyecto.')
  }
  const error = cuentas.error ?? asignaciones.error ?? movimientos.error ?? historial.error ?? categorias.error
  if (error) throw new Error('No se pudieron cargar los datos financieros. Vuelve a intentarlo.')
  return {
    cuentas: (cuentas.data ?? []) as Cuenta[],
    asignaciones: (asignaciones.data ?? []) as Asignacion[],
    movimientos: (movimientos.data ?? []) as Movimiento[],
    historial: (historial.data ?? []) as Historial[],
    categorias: (categorias.data ?? []) as Categoria[],
  }
}

const mensajes = [
  'Saldo insuficiente', 'Cuenta no encontrada', 'Ambas cuentas deben',
  'El saldo inicial ya fue registrado', 'Primero registra el saldo inicial',
  'La contraseña', 'El monto debe', 'La operación', 'Destino no válido',
  'Categoría no válida', 'Elige dos', 'Falta el identificador',
]

function comprobar(error: { message: string; code?: string } | null) {
  if (!error) return
  if (error.code === '23505') throw new Error('Esta operación ya se registró o el nombre de cuenta ya existe. Actualiza los datos antes de reintentar.')
  const claro = mensajes.some((inicio) => error.message.startsWith(inicio))
  throw new Error(claro ? error.message : 'No se pudo completar la operación. Revisa los datos e inténtalo otra vez.')
}

export async function crearCuenta(nombre: string, tipo: TipoCuenta) {
  const { error } = await supabase.rpc('finanzas_crear_cuenta', { p_nombre: nombre, p_tipo: tipo })
  comprobar(error)
}

export async function registrarSaldoInicial(cuentaId: string, monto: number, personal: number, negocio: number, ahorros: number, operacionId: string) {
  const { error } = await supabase.rpc('finanzas_registrar_saldo_inicial', {
    p_cuenta_id: cuentaId, p_monto: monto, p_personal: personal,
    p_negocio: negocio, p_ahorros: ahorros, p_operacion_id: operacionId,
  })
  comprobar(error)
}

export async function registrarMovimiento(cuentaId: string, tipo: 'ingreso' | 'gasto', monto: number, destino: Destino, descripcion: string, categoriaId: string | null, operacionId: string) {
  const { error } = await supabase.rpc('finanzas_registrar_movimiento', {
    p_cuenta_id: cuentaId, p_tipo: tipo, p_monto: monto, p_destino: destino,
    p_descripcion: descripcion, p_categoria_id: categoriaId, p_operacion_id: operacionId,
  })
  comprobar(error)
}

export async function transferir(origenId: string, destinoId: string, monto: number, descripcion: string, operacionId: string) {
  const { error } = await supabase.rpc('finanzas_transferir', {
    p_origen_id: origenId, p_destino_id: destinoId, p_monto: monto,
    p_descripcion: descripcion, p_operacion_id: operacionId,
  })
  comprobar(error)
}

export async function redistribuir(origen: Destino, destino: Destino, monto: number, descripcion: string, operacionId: string) {
  const { error } = await supabase.rpc('finanzas_redistribuir', {
    p_origen: origen, p_destino: destino, p_monto: monto,
    p_descripcion: descripcion, p_operacion_id: operacionId,
  })
  comprobar(error)
}
