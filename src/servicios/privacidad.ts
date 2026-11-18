import { createContext, useContext } from 'react'
import { soles } from './formato'

export type Privacidad = { visible: boolean; alternar: () => void }

export const ContextoPrivacidad = createContext<Privacidad>({ visible: true, alternar: () => undefined })

export const usePrivacidad = () => useContext(ContextoPrivacidad)

/** Devuelve un formateador de dinero que respeta "Ocultar montos" en toda la app. */
export function useDinero() {
  const { visible } = useContext(ContextoPrivacidad)
  return (valor: number) => (visible ? soles(valor) : 'S/ ••••')
}
