import "./App.css";
import { TodoProvider } from "./contexts/TodoContext";
import { TodoList } from "./components/TodoList";
import { AddTodo } from "./components/AddTodo";

function App() {
  return (
    <TodoProvider>
      <div className="app">
        <h1>Todo List</h1>
        <AddTodo />
        <TodoList />
      </div>
    </TodoProvider>
  );
}

export default App;
