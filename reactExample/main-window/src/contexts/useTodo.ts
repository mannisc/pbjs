// The context object and its hook live apart from the provider component on
// purpose: React Fast Refresh can only swap a module whose exports are all
// components, so a file exporting both `TodoProvider` and `useTodo` loses hot
// reload (and lints as react-refresh/only-export-components). Provider in
// TodoContext.tsx, everything else here.
//
// Named useTodo.ts, not todoContext.ts: a sibling differing from
// TodoContext.tsx only in casing resolves to the wrong file on a
// case-insensitive filesystem (`.ts` is tried before `.tsx`), and TypeScript
// then rejects the whole program with TS1149/TS1261.
import { createContext, useContext } from "react";

export interface Todo {
  id: number;
  text: string;
  completed: boolean;
}

export interface TodoContextType {
  todos: Todo[];
  addTodo: (text: string) => void;
  toggleTodo: (id: number) => void;
  removeTodo: (id: number) => void;
}

export const TodoContext = createContext<TodoContextType | undefined>(
  undefined
);

export function useTodo() {
  const context = useContext(TodoContext);
  if (context === undefined) {
    throw new Error("useTodo must be used within a TodoProvider");
  }
  return context;
}
