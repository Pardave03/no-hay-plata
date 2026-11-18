import { supabase } from './supabase'

type ErrorPg = { message: string; code?: string } | null

/** Convierte un error de Supabase en un mensaje claro para la persona. */
export function comprobar(error: ErrorPg) {
  if (!error) return
  // P0001: mensajes escritos por nuestras funciones SQL (raise exception), ya en lenguaje claro.
  if (error.code === 'P0001') throw new Error(error.message)
  if (error.code === '23505') throw new Error('Ese registro ya existe o la operación ya se registró. Actualiza antes de reintentar.')
  if (['PGRST205', 'PGRST202', '42P01', '42703', '42883'].includes(error.code ?? '')) {
    throw new Error('Esta sección necesita la última migración de la base de datos, que aún no está aplicada.')
  }
  throw new Error('No se pudo completar la operación. Revisa los datos e inténtalo otra vez.')
}

export async function rpc<T = unknown>(nombre: string, parametros?: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(nombre, parametros)
  comprobar(error)
  return data as T
}

/** Ejecuta una consulta y devuelve sus filas (RLS limita cada tabla a los datos propios). */
export async function filas<T>(consulta: PromiseLike<{ data: unknown; error: ErrorPg }>): Promise<T[]> {
  const { data, error } = await consulta
  comprobar(error)
  return (data ?? []) as T[]
}

export const mensajeError = (fallo: unknown) =>
  fallo instanceof Error ? fallo.message : 'Ocurrió un error inesperado.'
