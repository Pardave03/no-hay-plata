import { useCallback, useEffect, useState } from 'react'
import { mensajeError } from './rpc'

/**
 * Carga datos al montar y cada vez que cambia `parametro` o se llama a `recargar`.
 * `cargar` debe ser una función estable (definida fuera del componente).
 */
export function useCarga<T>(cargar: (parametro: string) => Promise<T>, parametro = '') {
  const [datos, setDatos] = useState<T | null>(null)
  const [error, setError] = useState('')
  const [cargando, setCargando] = useState(true)
  const [revision, setRevision] = useState(0)

  useEffect(() => {
    let activo = true
    cargar(parametro)
      .then((resultado) => { if (activo) { setDatos(resultado); setError('') } })
      .catch((fallo: unknown) => { if (activo) setError(mensajeError(fallo)) })
      .finally(() => { if (activo) setCargando(false) })
    return () => { activo = false }
  }, [cargar, parametro, revision])

  const recargar = useCallback(() => setRevision((actual) => actual + 1), [])
  return { datos, error, cargando, recargar }
}

/** Ejecuta acciones de guardado mostrando error o aviso y recargando los datos al terminar. */
export function useAccion(recargar: () => void) {
  const [guardando, setGuardando] = useState(false)
  const [error, setError] = useState('')
  const [aviso, setAviso] = useState('')

  async function ejecutar(accion: () => Promise<unknown>, exito = 'Guardado correctamente.') {
    setGuardando(true)
    setError('')
    setAviso('')
    try {
      await accion()
      setAviso(exito)
      recargar()
      return true
    } catch (fallo) {
      setError(mensajeError(fallo))
      return false
    } finally {
      setGuardando(false)
    }
  }

  return { guardando, error, aviso, ejecutar, setError }
}

/** Identificador de operación: evita registrar dos veces lo mismo si se reintenta un envío. */
export function useOperacion() {
  const [id, setId] = useState(() => crypto.randomUUID())
  const renovar = useCallback(() => setId(crypto.randomUUID()), [])
  return [id, renovar] as const
}
