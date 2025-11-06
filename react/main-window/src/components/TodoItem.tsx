import { useTodo } from "../contexts/TodoContext";

interface TodoItemProps {
  id: number;
  text: string;
  completed: boolean;
}

export function TodoItem({ id, text, completed }: TodoItemProps) {
  const { toggleTodo, removeTodo } = useTodo();

  return (
    <div className="todo-item">
      <input
        type="checkbox"
        checked={completed}
        onChange={() => toggleTodo(id)}
      />
      <span style={{ textDecoration: completed ? "line-through" : "none" }}>
        {text}
      </span>
      <button onClick={() => removeTodo(id)}>Delete</button>
    </div>
  );
}
